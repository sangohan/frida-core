namespace Zed.Agent {
	public class FruityServer : Object, AgentSession {
		public string listen_address {
			get;
			construct;
		}

		private MainLoop main_loop = new MainLoop ();
		private DBusServer server;
		private bool closing = false;
		private Gee.ArrayList<DBusConnection> connections = new Gee.ArrayList<DBusConnection> ();
		private Gee.HashMap<DBusConnection, uint> registration_id_by_connection = new Gee.HashMap<DBusConnection, uint> ();
		private ScriptEngine script_engine = new ScriptEngine ();

		public FruityServer (string listen_address) {
			Object (listen_address: listen_address);
		}

		construct {
			script_engine.message_from_script.connect ((script_id, msg) => this.message_from_script (script_id, msg));
		}

		public async void close () throws IOError {
			if (closing)
				throw new IOError.FAILED ("close already in progress");
			closing = true;

			server.stop ();
			server = null;

			if (script_engine != null) {
				script_engine.shutdown ();
				script_engine = null;
			}

			Timeout.add (100, () => {
				close_connections_and_schedule_shutdown ();
				return false;
			});
		}

		private async void close_connections_and_schedule_shutdown () {
			foreach (var connection in connections) {
				uint registration_id;
				if (registration_id_by_connection.unset (connection, out registration_id))
					connection.unregister_object (registration_id);

				try {
					yield connection.close ();
				} catch (IOError e) {
				}
			}
			connections.clear ();

			Timeout.add (100, () => {
				main_loop.quit ();
				return false;
			});
		}

		public async AgentModuleInfo[] query_modules () throws IOError {
			var modules = new Gee.ArrayList<AgentModuleInfo?> ();
			Gum.Process.enumerate_modules ((name, address, path) => {
				modules.add (AgentModuleInfo (name, path, 42, (uint64) address));
				return true;
			});
			return modules.to_array ();
		}

		public async AgentFunctionInfo[] query_module_functions (string module_name) throws IOError {
			var functions = new Gee.ArrayList<AgentFunctionInfo?> ();
			Gum.Module.enumerate_exports (module_name, (name, address) => {
				functions.add (AgentFunctionInfo (name, (uint64) address));
				return true;
			});
			if (functions.is_empty)
				functions.add (AgentFunctionInfo ("<placeholdertotemporarilyworkaroundemptylistbug>", 1337));
			return functions.to_array ();
		}

		public async uint8[] read_memory (uint64 address, uint size) throws IOError {
			var bytes = Gum.Memory.read ((void *) address, size);
			if (bytes.length == 0)
				throw new IOError.FAILED ("specified memory region is not readable");
			return bytes;
		}

		public async void start_investigation (AgentTriggerInfo start_trigger, AgentTriggerInfo stop_trigger) throws IOError {
			throw new IOError.FAILED ("not implemented");
		}

		public async void stop_investigation () throws IOError {
			throw new IOError.FAILED ("not implemented");
		}

		public async AgentScriptInfo attach_script_to (string script_text, uint64 address) throws IOError {
			var instance = script_engine.attach_script_to (script_text, address);
			var script = instance.script;
			return AgentScriptInfo (instance.id, (uint64) script.get_code_address (), script.get_code_size ());
		}

		public async void detach_script (uint script_id) throws IOError {
			script_engine.detach_script (script_id);
		}

		public async void begin_instance_trace () throws IOError {
			throw new IOError.FAILED ("not implemented");
		}

		public async void end_instance_trace () throws IOError {
			throw new IOError.FAILED ("not implemented");
		}

		public async AgentInstanceInfo[] peek_instances () throws IOError {
			throw new IOError.FAILED ("not implemented");
		}

		public void run () throws Error {
			server = new DBusServer.sync (listen_address, DBusServerFlags.AUTHENTICATION_ALLOW_ANONYMOUS, DBus.generate_guid ());
			server.new_connection.connect ((connection) => {
				try {
					Zed.AgentSession session = this;
					var registration_id = connection.register_object (Zed.ObjectPath.AGENT_SESSION, session);
					registration_id_by_connection[connection] = registration_id;
				} catch (IOError e) {
					printerr ("failed to register object: %s\n", e.message);
					return false;
				}

				connections.add (connection);
				return true;
			});

			server.start ();

			main_loop = new MainLoop ();
			main_loop.run ();
		}
	}

	public void main (string data_string) {
		var interceptor = Gum.Interceptor.obtain ();
		interceptor.ignore_caller ();

		var server = new FruityServer (data_string);

		try {
			server.run ();
		} catch (Error e) {
			printerr ("error: %s\n", e.message);
		}

		server = null;
		interceptor = null;

		Gum.deinit ();
		IO.deinit ();
		Thread.deinit ();
	}
}
