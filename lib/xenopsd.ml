(*
 * Copyright (C) Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Xenops_utils

module D = Debug.Make(struct let name = "xenopsd" end)
open D

let name = "xenopsd"

let major_version = 0
let minor_version = 9

let sockets_path = ref Xenops_interface.default_sockets_dir
let persist = ref true
let worker_pool_size = ref 4

let run_hotplug_scripts = ref true
let hotplug_timeout = ref 300.
let qemu_dm_ready_timeout = ref 300.
let vgpu_ready_timeout = ref 30.
let vgpu_suspend_timeout = ref 60.
let use_upstream_qemu = ref false

let watch_queue_length = ref 1000

let default_vbd_backend_kind = ref "vbd"
let ca_140252_workaround = ref false

let additional_ballooning_timeout = ref 120.
let vif_ready_timeout = ref 10

let options = [
    "queue", Arg.Set_string Xenops_interface.queue_name, (fun () -> !Xenops_interface.queue_name), "Listen on a specific queue";
    "sockets-path", Arg.Set_string sockets_path, (fun () -> !sockets_path), "Directory to create listening sockets";
    "persist", Arg.Bool (fun b -> persist := b), (fun () -> string_of_bool !persist), "True if we want to persist metadata across restarts";
    "worker-pool-size", Arg.Set_int worker_pool_size, (fun () -> string_of_int !worker_pool_size), "Number of threads for the worker pool";
    "database-path", Arg.String (fun x -> Xenops_utils.root := Some x), (fun () -> Xenops_utils.get_root ()), "Location to store the metadata";
    "run_hotplug_scripts", Arg.Bool (fun x -> run_hotplug_scripts := x), (fun () -> string_of_bool !run_hotplug_scripts), "True if xenopsd should execute the hotplug scripts directly";
    "hotplug_timeout", Arg.Set_float hotplug_timeout, (fun () -> string_of_float !hotplug_timeout), "Time before we assume hotplug scripts have failed";
    "qemu_dm_ready_timeout", Arg.Set_float qemu_dm_ready_timeout, (fun () -> string_of_float !qemu_dm_ready_timeout), "Time before we assume qemu has become stuck";
    "vgpu-ready-timeout", Arg.Set_float vgpu_ready_timeout, (fun () -> string_of_float !vgpu_ready_timeout), "Time before we assume vgpu has become stuck or unresponsive";
    "vgpu-suspend-timeout", Arg.Set_float vgpu_suspend_timeout, (fun () -> string_of_float !vgpu_suspend_timeout), "Time we allow vgpu to write its statefile";
    "watch_queue_length", Arg.Set_int watch_queue_length, (fun () -> string_of_int !watch_queue_length), "Maximum number of unprocessed xenstore watch events before we restart";
    "use-upstream-qemu", Arg.Bool (fun x -> use_upstream_qemu := x), (fun () -> string_of_bool !use_upstream_qemu), "True if we want to use upsteam QEMU";
    "default-vbd-backend-kind", Arg.Set_string default_vbd_backend_kind, (fun () -> !default_vbd_backend_kind), "Default backend for VBDs";
    "ca-140252-workaround", Arg.Bool (fun x -> ca_140252_workaround := x), (fun () -> string_of_bool !ca_140252_workaround), "Workaround for evtchn misalignment for legacy PV tools";
    "additional-ballooning-timeout", Arg.Set_float additional_ballooning_timeout, (fun () -> string_of_float !additional_ballooning_timeout), "Time we allow the guests to do additional memory ballooning before live migration";
    "vif_ready_timeout", Arg.Set_int vif_ready_timeout, (fun () -> string_of_int !vif_ready_timeout), "Time before we assume vif has connected";
]

let path () = Filename.concat !sockets_path "xenopsd"
let forwarded_path () = path () ^ ".forwarded" (* receive an authenticated fd from xapi *)
let json_path () = path () ^ ".json"


module Server = Xenops_interface.Server(Xenops_server)

let rpc_fn call =
	let context = { Xenops_server.transferred_fd = None } in
	Server.process context call

let handle_received_fd this_connection =
	let msg_size = 16384 in
	let buf = String.make msg_size '\000' in
	debug "Calling recv_fd()";
	let len, _, received_fd = Fd_send_recv.recv_fd this_connection buf 0 msg_size [] in
	debug "recv_fd ok (len = %d)" len;
	finally
		(fun () ->
			let req = String.sub buf 0 len |> Jsonrpc.of_string |> Xenops_migrate.Forwarded_http_request.t_of_rpc in
			debug "Received request = [%s]\n%!" (req |> Xenops_migrate.Forwarded_http_request.rpc_of_t |> Jsonrpc.to_string);
			let expected_prefix = "/services/xenops/memory/" in
			let uri = req.Xenops_migrate.Forwarded_http_request.uri in
			if String.length uri < String.length expected_prefix || (String.sub uri 0 (String.length expected_prefix) <> expected_prefix) then begin
				error "Expected URI prefix %s, got %s" expected_prefix uri;
				let module Response = Cohttp.Response.Make(Cohttp_posix_io.Unbuffered_IO) in
				let headers = Cohttp.Header.of_list [
					"User-agent", "xenopsd"
				] in
				let response = Cohttp.Response.make ~version:`HTTP_1_1 ~status:`Not_found ~headers () in
				Response.write (fun _ -> ()) response this_connection;
			end else begin
				let context = {
					Xenops_server.transferred_fd = Some received_fd
				} in
				let uri = Uri.of_string req.Xenops_migrate.Forwarded_http_request.uri in
				Xenops_server.VM.receive_memory uri req.Xenops_migrate.Forwarded_http_request.cookie this_connection context
			end
		) (fun () -> Unix.close received_fd)

let doc = String.concat "\n" [
	"This is the xapi toolstack domain management daemon.";
	"";
	"Xenopsd looks after a set of Xen domains, performing lifecycle operations including start/shutdown/migrate. A system may run multiple xenopsds, each looking after a different set of VMs. Xenopsd will always ignore domains that it hasn't been asked to manage. There are multiple xenopsd *backends*, including 'xc': which uses libxc directly and 'xenlight': which uses the new Xen libxl library (recommended).";
]

       

let configure ?(specific_options=[]) ?(specific_essential_paths=[]) ?(specific_nonessential_paths=[]) () =
	Debug.set_facility Syslog.Local5;

	debug "xenopsd version %d.%d starting" major_version minor_version;

	let options = options @ specific_options in
	let resources = Resources.make_resources
		~essentials:(Resources.essentials @ specific_essential_paths)
		~nonessentials:(Resources.nonessentials @ specific_nonessential_paths) in
	match Xcp_service.configure2
		~name:(Filename.basename Sys.argv.(0))
		~version:Version.version
		~doc ~options ~resources () with
	| `Ok () -> ()
	| `Error m ->
		error "%s" m;
		exit 1


let main backend =
	Printexc.record_backtrace true;

	(* Listen for transferred file descriptors *)
	let forwarded_server = Xcp_service.make_socket_server (forwarded_path ())
		handle_received_fd in

	(* TODO: this should be indirected through the switch *)

	(* Listen for regular API calls *)
	let xml_server = Xcp_service.make
		~path:(path ())
		~queue_name:!Xenops_interface.queue_name
		~rpc_fn
	        () in

  (** we need to catch this to make sure at_exit handlers are
   * triggered. In particuar, triggers for the bisect_ppx coverage
   * profiling *)

  let signal_handler n =
    debug "caught signal %d" n; exit 0 in

	Xcp_service.maybe_daemonize ();

	Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Sys.set_signal Sys.sigterm (Sys.Signal_handle signal_handler);
  

	Xenops_utils.set_fs_backend
		(Some (if !persist
			then (module Xenops_utils.FileFS: Xenops_utils.FS)
			else (module Xenops_utils.MemFS: Xenops_utils.FS)));

	Xenops_server.register_objects();
	Xenops_server.set_backend (Some backend);

	Debug.with_thread_associated "main"
	(fun () ->
(*
		let (_: Thread.t) = Thread.create (fun () -> Xcp_service.serve_forever domain_server) () in *)
		let (_: Thread.t) = Thread.create (fun () -> Xcp_service.serve_forever forwarded_server) () in
		let (_: Thread.t) = Thread.create (fun () -> Xcp_service.serve_forever xml_server) () in
		()
	) ();
	Xenops_server.WorkerPool.start !worker_pool_size;
	while true do
		try
			Thread.delay 60.
		with e ->
			debug "Thread.delay caught: %s" (Printexc.to_string e)
	done

(* Verify the signature matches *)
module S = (Xenops_server_skeleton : Xenops_server_plugin.S)
