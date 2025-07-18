(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
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
open Xapi_stdext_pervasives.Pervasiveext

exception Unix_error of int

let _exit = Unix._exit

let raise_with_preserved_backtrace exn f =
  let bt = Printexc.get_raw_backtrace () in
  f () ;
  Printexc.raise_with_backtrace exn bt

(** remove a file, but doesn't raise an exception if the file is already removed *)
let unlink_safe file =
  try Unix.unlink file with (* Unix.Unix_error (Unix.ENOENT, _ , _)*) _ -> ()

(** create a directory but doesn't raise an exception if the directory already exist *)
let mkdir_safe dir perm =
  try Unix.mkdir dir perm with Unix.Unix_error (Unix.EEXIST, _, _) -> ()

(** create a directory, and create parent if doesn't exist *)
let mkdir_rec dir perm =
  let rec p_mkdir dir =
    let p_name = Filename.dirname dir in
    if p_name <> "/" && p_name <> "." then
      p_mkdir p_name ;
    mkdir_safe dir perm
  in
  p_mkdir dir

(** removes a file or recursively removes files/directories below a directory without following
    symbolic links. If path is a directory, it is only itself removed if rm_top is true. If path
    is non-existent nothing happens, it does not lead to an error. *)
let rm_rec ?(rm_top = true) path =
  let ( // ) = Filename.concat in
  let rec rm rm_top path =
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        () (*noop*)
    | exception e ->
        raise e
    | st -> (
      match st.Unix.st_kind with
      | Unix.S_DIR ->
          Sys.readdir path |> Array.iter (fun file -> rm true (path // file)) ;
          if rm_top then Unix.rmdir path
      | _ ->
          Unix.unlink path
    )
  in
  rm rm_top path

(** write a pidfile file *)
let pidfile_write filename =
  let fd =
    Unix.openfile filename [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o640
  in
  finally
    (fun () ->
      let pid = Unix.getpid () in
      let buf = string_of_int pid ^ "\n" in
      let len = String.length buf in
      if Unix.write fd (Bytes.unsafe_of_string buf) 0 len <> len then
        failwith "pidfile_write failed"
    )
    (fun () -> Unix.close fd)

(** read a pidfile file, return either Some pid or None *)
let pidfile_read filename =
  let fd = Unix.openfile filename [Unix.O_RDONLY] 0o640 in
  finally
    (fun () ->
      try
        let buf = Bytes.create 80 in
        let rd = Unix.read fd buf 0 (Bytes.length buf) in
        if rd = 0 then
          failwith "pidfile_read failed" ;
        Scanf.sscanf (Bytes.sub_string buf 0 rd) "%d" (fun i -> Some i)
      with _ -> None
    )
    (fun () -> Unix.close fd)

(** open a file, and make sure the close is always done *)
let with_file file mode perms f =
  let fd = Unix.openfile file mode perms in
  Xapi_stdext_pervasives.Pervasiveext.finally
    (fun () -> f fd)
    (fun () -> Unix.close fd)

exception Break

let lines_fold f start input =
  let accumulator = ref start in
  let running = ref true in
  while !running do
    let line = try Some (input_line input) with End_of_file -> None in
    match line with
    | Some line -> (
      try accumulator := f !accumulator line with Break -> running := false
    )
    | None ->
        running := false
  done ;
  !accumulator

let lines_iter f = lines_fold (fun () line -> ignore (f line)) ()

(** open a file, and make sure the close is always done *)
let with_input_channel file f =
  let input = open_in file in
  finally (fun () -> f input) (fun () -> close_in input)

let file_lines_fold f start file_path =
  with_input_channel file_path (lines_fold f start)

let read_lines ~(path : string) : string list =
  List.rev (file_lines_fold (fun acc line -> line :: acc) [] path)

let file_lines_iter f = file_lines_fold (fun () line -> ignore (f line)) ()

let readfile_line = file_lines_iter

(** [fd_blocks_fold block_size f start fd] folds [f] over blocks (strings)
    from the fd [fd] with initial value [start] *)
let fd_blocks_fold block_size f start fd =
  let block = Bytes.create block_size in
  let rec fold acc =
    let n = Unix.read fd block 0 block_size in
    (* Consider making the interface explicitly use Substrings *)
    let b = if n = block_size then block else Bytes.sub block 0 n in
    if n = 0 then acc else fold (f acc b)
  in
  fold start

let with_directory dir f =
  let dh = Unix.opendir dir in
  Xapi_stdext_pervasives.Pervasiveext.finally
    (fun () -> f dh)
    (fun () -> Unix.closedir dh)

let buffer_of_fd fd =
  fd_blocks_fold 1024
    (fun b s -> Buffer.add_bytes b s ; b)
    (Buffer.create 1024) fd

let string_of_fd fd = Buffer.contents (buffer_of_fd fd)

let buffer_of_file file_path =
  with_file file_path [Unix.O_RDONLY] 0 buffer_of_fd

let string_of_file file_path = Buffer.contents (buffer_of_file file_path)

(** Write a file, ensures atomicity and durability. *)
let atomic_write_to_file fname perms f =
  let dir_path = Filename.dirname fname in
  let tmp_path, tmp_chan =
    Filename.open_temp_file ~temp_dir:dir_path "" ".tmp"
  in
  let tmp_fd = Unix.descr_of_out_channel tmp_chan in
  let write_tmp_file () =
    let result = f tmp_fd in
    Unix.fchmod tmp_fd perms ; Unix.fsync tmp_fd ; result
  in
  let write_and_persist () =
    let result = finally write_tmp_file (fun () -> Stdlib.close_out tmp_chan) in
    Unix.rename tmp_path fname ;
    (* sync parent directory to make sure the file is persisted *)
    let dir_fd = Unix.openfile dir_path [O_RDONLY] 0 in
    finally (fun () -> Unix.fsync dir_fd) (fun () -> Unix.close dir_fd) ;
    result
  in
  finally write_and_persist (fun () -> unlink_safe tmp_path)

(** Atomically write a string to a file *)
let write_bytes_to_file ?(perms = 0o644) fname b =
  atomic_write_to_file fname perms (fun fd ->
      let len = Bytes.length b in
      let written = Unix.write fd b 0 len in
      if written <> len then failwith "Short write occured!"
  )

let write_string_to_file ?(perms = 0o644) fname s =
  write_bytes_to_file fname ~perms (Bytes.unsafe_of_string s)

let execv_get_output cmd args =
  let pipe_exit, pipe_entrance = Unix.pipe () in
  let r =
    try
      Unix.set_close_on_exec pipe_exit ;
      true
    with _ -> false
  in
  match Unix.fork () with
  | 0 -> (
      Unix.dup2 pipe_entrance Unix.stdout ;
      Unix.close pipe_entrance ;
      if not r then
        Unix.close pipe_exit ;
      try Unix.execv cmd args with _ -> exit 127
    )
  | pid ->
      Unix.close pipe_entrance ; (pid, pipe_exit)

let copy_file_internal ?limit reader writer =
  let buffer = Bytes.make 65536 '\000' in
  let buffer_len = Int64.of_int (Bytes.length buffer) in
  let finished = ref false in
  let total_bytes = ref 0L in
  let limit = ref limit in
  while not !finished do
    let requested = min (Option.value ~default:buffer_len !limit) buffer_len in
    let num = reader buffer 0 (Int64.to_int requested) in
    let num64 = Int64.of_int num in
    limit := Option.map (fun x -> Int64.sub x num64) !limit ;
    ignore (writer buffer 0 num : int) ;
    total_bytes := Int64.add !total_bytes num64 ;
    finished := num = 0 || !limit = Some 0L
  done ;
  !total_bytes

let copy_file ?limit ifd ofd =
  copy_file_internal ?limit (Unix.read ifd) (Unix.write ofd)

let file_exists file_path =
  try
    Unix.access file_path [Unix.F_OK] ;
    true
  with _ -> false

let touch_file file_path =
  let fd =
    Unix.openfile file_path
      [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_NOCTTY; Unix.O_NONBLOCK]
      0o666
  in
  Unix.close fd ;
  Unix.utimes file_path 0.0 0.0

let is_empty_file file_path =
  try
    let stats = Unix.stat file_path in
    stats.Unix.st_size = 0
  with Unix.Unix_error (Unix.ENOENT, _, _) -> false

let delete_empty_file file_path =
  if is_empty_file file_path then (
    Sys.remove file_path ; true
  ) else
    false

(** Create a new file descriptor, connect it to host:port and return it *)
exception Host_not_found of string

let open_connection_fd host port =
  let open Unix in
  let addrinfo =
    getaddrinfo host (string_of_int port) [AI_SOCKTYPE SOCK_STREAM]
  in
  match addrinfo with
  | [] ->
      failwith (Printf.sprintf "Couldn't resolve hostname: %s" host)
  | ai :: _ -> (
      let s = socket ai.ai_family ai.ai_socktype 0 in
      try connect s ai.ai_addr ; s
      with e -> Backtrace.is_important e ; close s ; raise e
    )

let open_connection_unix_fd filename =
  let s = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  try
    let addr = Unix.ADDR_UNIX filename in
    Unix.connect s addr ; s
  with e -> Backtrace.is_important e ; Unix.close s ; raise e

module CBuf = struct
  (** A circular buffer constructed from a string *)
  type t = {
      buffer: bytes
    ; mutable len: int  (** bytes of valid data in [buffer] *)
    ; mutable start: int  (** index of first valid byte in [buffer] *)
    ; mutable r_closed: bool  (** true if no more data can be read due to EOF *)
    ; mutable w_closed: bool
          (** true if no more data can be written due to EOF *)
  }

  let empty length =
    {
      buffer= Bytes.create length
    ; len= 0
    ; start= 0
    ; r_closed= false
    ; w_closed= false
    }

  let drop (x : t) n =
    if n > x.len then failwith (Printf.sprintf "drop %d > %d" n x.len) ;
    x.start <- (x.start + n) mod Bytes.length x.buffer ;
    x.len <- x.len - n

  let should_read (x : t) =
    (not x.r_closed) && x.len < Bytes.length x.buffer - 1

  let should_write (x : t) = (not x.w_closed) && x.len > 0

  let end_of_reads (x : t) = x.r_closed && x.len = 0

  let end_of_writes (x : t) = x.w_closed

  let write (x : t) fd =
    (* Offset of the character after the substring *)
    let next = min (Bytes.length x.buffer) (x.start + x.len) in
    let len = next - x.start in
    let written =
      try Unix.single_write fd x.buffer x.start len
      with _ ->
        x.w_closed <- true ;
        len
    in
    drop x written

  let read (x : t) fd =
    (* Offset of the next empty character *)
    let next = (x.start + x.len) mod Bytes.length x.buffer in
    let len =
      min (Bytes.length x.buffer - next) (Bytes.length x.buffer - x.len)
    in
    let read = Unix.read fd x.buffer next len in
    if read = 0 then x.r_closed <- true ;
    x.len <- x.len + read
end

exception Process_still_alive

let kill_and_wait ?(signal = Sys.sigterm) ?(timeout = 10.) pid =
  let proc_entry_exists pid =
    try
      Unix.access (Printf.sprintf "/proc/%d" pid) [Unix.F_OK] ;
      true
    with _ -> false
  in
  if pid > 0 && proc_entry_exists pid then (
    let loop_time_waiting = 0.03 in
    let left = ref timeout in
    let readcmdline pid =
      try string_of_file (Printf.sprintf "/proc/%d/cmdline" pid) with _ -> ""
    in
    let reference = readcmdline pid and quit = ref false in
    Unix.kill pid signal ;
    (* We cannot do a waitpid here, since we might not be parent of
       		   the process, so instead we are waiting for the /proc/%d to go
       		   away. Also we verify that the cmdline stay the same if it's still here
       		   to prevent the very very unlikely event that the pid get reused before
       		   we notice it's gone *)
    while proc_entry_exists pid && (not !quit) && !left > 0. do
      let cmdline = readcmdline pid in
      if cmdline = reference then (
        (* still up, let's sleep a bit *)
        Thread.delay loop_time_waiting ;
        left := !left -. loop_time_waiting
      ) else (* not the same, it's gone ! *)
        quit := true
    done ;
    if !left <= 0. then
      raise Process_still_alive
  )

let with_polly f =
  let polly = Polly.create () in
  let finally () = Polly.close polly in
  Xapi_stdext_pervasives.Pervasiveext.finally (fun () -> f polly) finally

let proxy (a : Unix.file_descr) (b : Unix.file_descr) =
  let size = 64 * 1024 in
  (* [a'] is read from [a] and will be written to [b] *)
  (* [b'] is read from [b] and will be written to [a] *)
  let a' = CBuf.empty size and b' = CBuf.empty size in
  Unix.set_nonblock a ;
  Unix.set_nonblock b ;
  with_polly @@ fun polly ->
  Polly.add polly a Polly.Events.empty ;
  Polly.add polly b Polly.Events.empty ;
  try
    while true do
      (* use oneshot notification so that we can use Polly.mod as needed to reenable,
         but it will disable itself each turn *)
      let a_events =
        Polly.Events.(
          (if CBuf.should_read a' then inp lor oneshot else empty)
          lor if CBuf.should_write b' then out lor oneshot else empty
        )
      and b_events =
        Polly.Events.(
          (if CBuf.should_read b' then inp lor oneshot else empty)
          lor if CBuf.should_write a' then out lor oneshot else empty
        )
      in
      (* If we can't make any progress (because fds have been closed), then stop *)
      if Polly.Events.(a_events lor b_events = empty) then raise End_of_file ;

      if Polly.Events.(a_events <> empty) then
        Polly.upd polly a a_events ;
      if Polly.Events.(b_events <> empty) then
        Polly.upd polly b b_events ;
      Polly.wait_fold polly 4 (-1) () (fun _polly fd events () ->
          (* Do the writing before the reading *)
          if Polly.Events.(test out events) then
            if a = fd then CBuf.write b' a else CBuf.write a' b ;
          if Polly.Events.(test inp events) then
            if a = fd then CBuf.read a' a else CBuf.read b' b
      ) ;
      (* If there's nothing else to read or write then signal the other end *)
      List.iter
        (fun (buf, fd) ->
          if CBuf.end_of_reads buf then Unix.shutdown fd Unix.SHUTDOWN_SEND ;
          if CBuf.end_of_writes buf then Unix.shutdown fd Unix.SHUTDOWN_RECEIVE
        )
        [(a', b); (b', a)]
    done
  with _ -> (
    (try Unix.clear_nonblock a with _ -> ()) ;
    (try Unix.clear_nonblock b with _ -> ()) ;
    (try Unix.close a with _ -> ()) ;
    try Unix.close b with _ -> ()
  )

let try_read_string ?limit fd =
  let buf = Buffer.create 0 in
  let chunk = match limit with None -> 4096 | Some x -> x in
  let cache = Bytes.make chunk '\000' in
  let finished = ref false in
  while not !finished do
    let to_read =
      match limit with
      | Some x ->
          min (x - Buffer.length buf) chunk
      | None ->
          chunk
    in
    let read_bytes = Unix.read fd cache 0 to_read in
    Buffer.add_subbytes buf cache 0 read_bytes ;
    if read_bytes = 0 then finished := true
  done ;
  Buffer.contents buf

(* From https://ocaml.github.io/ocamlunix/ocamlunix.html#sec118
   The function write of the Unix module iterates the system call write until
   all the requested bytes are effectively written.
   val write : file_descr -> string -> int -> int -> int
   However, when the descriptor is a pipe (or a socket, see chapter 6), writes
   may block and the system call write may be interrupted by a signal. In this
   case the OCaml call to Unix.write is interrupted and the error EINTR is raised.
   The problem is that some of the data may already have been written by a
   previous system call to write but the actual size that was transferred is
   unknown and lost. This renders the function write of the Unix module useless
   in the presence of signals.

   To address this problem, the Unix module also provides the “raw” system call
   write under the name single_write.

   We can use multiple single_write calls to write exactly the requested
   amount of data (but not atomically!).
*)
let rec restart_on_EINTR f x =
  try f x with Unix.Unix_error (Unix.EINTR, _, _) -> restart_on_EINTR f x

and really_write fd buffer offset len =
  let n = restart_on_EINTR (Unix.single_write_substring fd buffer offset) len in
  if n < len then really_write fd buffer (offset + n) (len - n)

(* Ideally, really_write would be implemented with optional arguments ?(off=0) ?(len=String.length string) *)
let really_write_string fd string =
  really_write fd string 0 (String.length string)

let rec really_read fd string off n =
  if n = 0 then
    ()
  else
    let m = restart_on_EINTR (Unix.read fd string off) n in
    if m = 0 then raise End_of_file ;
    really_read fd string (off + m) (n - m)

let really_read_string fd length =
  let buf = Bytes.make length '\000' in
  really_read fd buf 0 length ;
  Bytes.unsafe_to_string buf

(* --------------------------------------------------------------------------------------- *)
(* Functions to read and write to/from a file descriptor with a given latest response time *)

exception Timeout

let to_milliseconds ms = ms *. 1000. |> ceil |> int_of_float

(* Allocating a new polly and waiting like this results in at least 3 syscalls.
   An alternative for sockets would be to use [setsockopt],
   but that would need 3 system calls too:

   [fstat] to check that it is not a pipe
    (you'd risk getting stuck forever without [select/poll/epoll] there)
   [setsockopt_float] to set the timeout
   [clear_nonblock] to ensure the socket is non-blocking
*)
let with_polly_wait kind fd f =
  match Unix.(LargeFile.fstat fd).st_kind with
  | S_DIR ->
      failwith "File descriptor cannot be a directory for read/write"
  | S_LNK ->
      (* should never happen, the file is already open and OCaml doesn't support O_SYMLINK to open the link itself *)
      failwith "cannot read/write into a symbolic link"
  | S_REG | S_BLK ->
      (* the best we can do is to split up the read/write operation into 64KiB chunks,
         and check the timeout after each chunk.
         select() would've silently succeeded here, whereas epoll() is stricted and returns EPERM
      *)
      let wait remaining_time = if remaining_time < 0. then raise Timeout in
      f wait fd
  | S_CHR | S_FIFO | S_SOCK ->
      with_polly @@ fun polly ->
      Polly.add polly fd kind ;
      let wait remaining_time =
        let milliseconds = to_milliseconds remaining_time in
        if milliseconds <= 0 then raise Timeout ;
        let ready =
          Polly.wait polly 1 milliseconds @@ fun _ event_on_fd _ ->
          assert (event_on_fd = fd)
        in
        if ready = 0 then raise Timeout
      in
      f wait fd

(* Write as many bytes to a file descriptor as possible from data before a given clock time. *)
(* Raises Timeout exception if the number of bytes written is less than the specified length. *)
(* Writes into the file descriptor at the current cursor position. *)
let time_limited_write_internal
    (write : Unix.file_descr -> 'a -> int -> int -> int) filedesc length data
    target_response_time =
  with_polly_wait Polly.Events.out filedesc @@ fun wait filedesc ->
  let total_bytes_to_write = length in
  let bytes_written = ref 0 in
  let now = ref (Unix.gettimeofday ()) in
  while !bytes_written < total_bytes_to_write && !now < target_response_time do
    let remaining_time = target_response_time -. !now in
    wait remaining_time ;
    let bytes_to_write = total_bytes_to_write - !bytes_written in
    let bytes =
      try write filedesc data !bytes_written bytes_to_write
      with
      | Unix.Unix_error (Unix.EAGAIN, _, _)
      | Unix.Unix_error (Unix.EWOULDBLOCK, _, _)
      ->
        0
    in
    (* write from buffer=data from offset=bytes_written, length=bytes_to_write *)
    bytes_written := bytes + !bytes_written ;
    now := Unix.gettimeofday ()
  done ;
  if !bytes_written = total_bytes_to_write then
    ()
  else (* we ran out of time *)
    raise Timeout

let time_limited_write filedesc length data target_response_time =
  time_limited_write_internal Unix.single_write filedesc length data
    target_response_time

let time_limited_write_substring filedesc length data target_response_time =
  time_limited_write_internal Unix.single_write_substring filedesc length data
    target_response_time

(* Read as many bytes to a file descriptor as possible before a given clock time. *)
(* Raises Timeout exception if the number of bytes read is less than the desired number. *)
(* Reads from the file descriptor at the current cursor position. *)
let time_limited_read filedesc length target_response_time =
  with_polly_wait Polly.Events.inp filedesc @@ fun wait filedesc ->
  let total_bytes_to_read = length in
  let bytes_read = ref 0 in
  let buf = Bytes.make total_bytes_to_read '\000' in
  let now = ref (Unix.gettimeofday ()) in
  while !bytes_read < total_bytes_to_read && !now < target_response_time do
    let remaining_time = target_response_time -. !now in
    wait remaining_time ;
    let bytes_to_read = total_bytes_to_read - !bytes_read in
    let bytes =
      try Unix.read filedesc buf !bytes_read bytes_to_read
      with
      | Unix.Unix_error (Unix.EAGAIN, _, _)
      | Unix.Unix_error (Unix.EWOULDBLOCK, _, _)
      ->
        0
    in
    (* read into buffer=buf from offset=bytes_read, length=bytes_to_read *)
    if bytes = 0 then
      raise End_of_file (* End of file has been reached *)
    else
      bytes_read := bytes + !bytes_read ;
    now := Unix.gettimeofday ()
  done ;
  if !bytes_read = total_bytes_to_read then
    Bytes.unsafe_to_string buf
  else (* we ran out of time *)
    raise Timeout

let time_limited_single_read filedesc length ~max_wait =
  let buf = Bytes.make length '\000' in
  with_polly_wait Polly.Events.inp filedesc @@ fun wait filedesc ->
  wait max_wait ;
  let bytes =
    try Unix.read filedesc buf 0 length
    with
    | Unix.Unix_error (Unix.EAGAIN, _, _)
    | Unix.Unix_error (Unix.EWOULDBLOCK, _, _)
    ->
      0
  in
  Bytes.sub_string buf 0 bytes

(** see [select(2)] "Correspondence between select() and poll() notifications".
    Note that HUP and ERR are ignored in events and returned only in revents.
    For simplicity we use the same event mask from the manual in both cases
 *)
let pollin_set = Polly.Events.(rdnorm lor rdband lor inp lor hup lor err)

let pollout_set = Polly.Events.(wrband lor wrnorm lor out lor err)

let pollerr_set = Polly.Events.pri

let to_milliseconds ms = ms *. 1e3 |> ceil |> int_of_float

(* we could change lists to proper Sets once the Unix.select to Unixext.select conversion is done *)

let readable fd (rd, wr, ex) = (fd :: rd, wr, ex)

let writable fd (rd, wr, ex) = (rd, fd :: wr, ex)

let error fd (rd, wr, ex) = (rd, wr, fd :: ex)

let check_events fd mask event action state =
  if Polly.Events.test mask event then
    action fd state
  else
    state

let no_events = ([], [], [])

let fold_events _ fd event state =
  state
  |> check_events fd pollin_set event readable
  |> check_events fd pollout_set event writable
  |> check_events fd pollerr_set event error

let polly_fold_add polly events action immediate fd =
  try Polly.add polly fd events ; immediate
  with Unix.Unix_error (Unix.EPERM, _, _) ->
    (* matches the behaviour of select: file descriptors that cannot be watched
       are returned as ready immediately *)
    action fd immediate

let polly_fold polly events fds action immediate =
  List.fold_left (polly_fold_add polly events action) immediate fds

let select ins outs errs timeout =
  (* -1.0 is a special value used in forkexecd *)
  if timeout < 0. && timeout <> -1.0 then
    invalid_arg (Printf.sprintf "negative timeout would hang: %g" timeout) ;
  match (ins, outs, errs) with
  | [], [], [] ->
      Unix.sleepf timeout ; no_events
  | _ -> (
      with_polly @@ fun polly ->
      (* file descriptors that cannot be watched by epoll *)
      let immediate =
        no_events
        |> polly_fold polly pollin_set ins readable
        |> polly_fold polly pollout_set outs writable
        |> polly_fold polly pollerr_set errs error
      in
      match immediate with
      | [], [], [] ->
          Polly.wait_fold polly 1024 (to_milliseconds timeout) no_events
            fold_events
      | _ ->
          (* we have some fds that are immediately available, but still poll the others
             for any events that are available immediately
          *)
          Polly.wait_fold polly 1024 0 immediate fold_events
    )

(* --------------------------------------------------------------------------------------- *)

(* Read a given number of bytes of data from the fd, or stop at EOF, whichever comes first. *)
(* A negative ~max_bytes indicates that all the data should be read from the fd until EOF. This is the default. *)
let read_data_in_chunks_internal (sub : bytes -> int -> int -> 'a)
    (f : 'a -> int -> unit) ?(block_size = 1024) ?(max_bytes = -1) from_fd =
  let buf = Bytes.make block_size '\000' in
  let rec do_read acc =
    let remaining_bytes = max_bytes - acc in
    if remaining_bytes = 0 then
      acc (* we've read the amount requested *)
    else
      let bytes_to_read =
        if max_bytes < 0 || remaining_bytes > block_size then
          block_size
        else
          remaining_bytes
      in
      let bytes_read = Unix.read from_fd buf 0 bytes_to_read in
      if bytes_read = 0 then
        acc (* we reached EOF *)
      else (
        f (sub buf 0 bytes_read) bytes_read ;
        do_read (acc + bytes_read)
      )
  in
  do_read 0

let read_data_in_string_chunks (f : string -> int -> unit) ?(block_size = 1024)
    ?(max_bytes = -1) from_fd =
  read_data_in_chunks_internal Bytes.sub_string f ~block_size ~max_bytes from_fd

let read_data_in_chunks (f : bytes -> int -> unit) ?(block_size = 1024)
    ?(max_bytes = -1) from_fd =
  read_data_in_chunks_internal Bytes.sub f ~block_size ~max_bytes from_fd

let spawnvp ?(pid_callback = fun _ -> ()) cmd args =
  match Unix.fork () with
  | 0 ->
      Unix.execvp cmd args
  | pid ->
      (try pid_callback pid with _ -> ()) ;
      snd (Unix.waitpid [] pid)

let double_fork f =
  match Unix.fork () with
  | 0 -> (
    match Unix.fork () with
    (* NB: use _exit (calls C lib _exit directly) to avoid
       		     calling at_exit handlers and flushing output channels
       		     which wouild cause intermittent deadlocks if we
       		     forked from a threaded program *)
    | 0 ->
        (try f () with _ -> ()) ;
        _exit 0
    | _ ->
        _exit 0
  )
  | pid ->
      ignore (Unix.waitpid [] pid)

external set_tcp_nodelay : Unix.file_descr -> bool -> unit
  = "stub_unixext_set_tcp_nodelay"

external set_sock_keepalives : Unix.file_descr -> int -> int -> int -> unit
  = "stub_unixext_set_sock_keepalives"

external fsync : Unix.file_descr -> unit = "stub_unixext_fsync"

external blkgetsize64 : Unix.file_descr -> int64 = "stub_unixext_blkgetsize64"

external get_max_fd : unit -> int = "stub_unixext_get_max_fd"

let int_of_file_descr (x : Unix.file_descr) : int = Obj.magic x

let file_descr_of_int (x : int) : Unix.file_descr = Obj.magic x

(** Forcibly closes all open file descriptors except those explicitly passed in as arguments.
    Useful to avoid accidentally passing a file descriptor opened in another thread to a
    process being concurrently fork()ed (there's a race between open/set_close_on_exec).
    NB this assumes that 'type Unix.file_descr = int'
*)
let close_all_fds_except (fds : Unix.file_descr list) =
  (* get at the file descriptor within *)
  let fds' = List.map int_of_file_descr fds in
  let close' (x : int) = try Unix.close (file_descr_of_int x) with _ -> () in
  let highest_to_keep = List.fold_left max (-1) fds' in
  (* close all the fds higher than the one we want to keep *)
  for i = highest_to_keep + 1 to get_max_fd () do
    close' i
  done ;
  (* close all the rest *)
  for i = 0 to highest_to_keep - 1 do
    if not (List.mem i fds') then close' i
  done

(** Remove "." and ".." from paths (NB doesn't attempt to resolve symlinks) *)
let resolve_dot_and_dotdot (path : string) : string =
  let of_string (x : string) : string list =
    let rec rev_split path =
      let basename = Filename.basename path
      and dirname = Filename.dirname path in
      let rest =
        if Filename.dirname dirname = dirname then [] else rev_split dirname
      in
      basename :: rest
    in
    let abs_path path =
      if Filename.is_relative path then
        Filename.concat "/" path (* no notion of a cwd *)
      else
        path
    in
    rev_split (abs_path x)
  in
  let to_string (x : string list) =
    List.fold_left Filename.concat "/" (List.rev x)
  in
  (* Process all "." and ".." references *)
  let rec remove_dots (n : int) (x : string list) =
    match (x, n) with
    | [], _ ->
        []
    | "." :: rest, _ ->
        remove_dots n rest (* throw away ".", don't count as parent for ".." *)
    | ".." :: rest, _ ->
        remove_dots (n + 1) rest (* note the number of ".." *)
    | x :: rest, 0 ->
        x :: remove_dots 0 rest
    | _ :: rest, n ->
        remove_dots (n - 1) rest (* munch *)
  in
  to_string (remove_dots 0 (of_string path))

(** Seek to an absolute offset within a file descriptor *)
let seek_to fd pos = Unix.lseek fd pos Unix.SEEK_SET

(** Seek to an offset within a file descriptor, relative to the current cursor position *)
let seek_rel fd diff = Unix.lseek fd diff Unix.SEEK_CUR

(** Return the current cursor position within a file descriptor *)
let current_cursor_pos fd =
  (* 'seek' to the current position, exploiting the return value from Unix.lseek as the new cursor position *)
  Unix.lseek fd 0 Unix.SEEK_CUR

let wait_for_path path delay timeout =
  let rec inner ttl =
    if ttl = 0 then failwith "No path!" ;
    try ignore (Unix.stat path)
    with _ ->
      delay 0.5 ;
      inner (ttl - 1)
  in
  inner (timeout * 2)

let _ = Callback.register_exception "unixext.unix_error" (Unix_error 0)

let send_fd = Fd_send_recv.send_fd

let send_fd_substring = Fd_send_recv.send_fd_substring

let recv_fd = Fd_send_recv.recv_fd

type statvfs_t = {
    f_bsize: int64
  ; f_frsize: int64
  ; f_blocks: int64
  ; f_bfree: int64
  ; f_bavail: int64
  ; f_files: int64
  ; f_ffree: int64
  ; f_favail: int64
  ; f_fsid: int64
  ; f_flag: int64
  ; f_namemax: int64
}

external statvfs : string -> statvfs_t = "stub_statvfs"

(** Returns Some Unix.PF_INET or Some Unix.PF_INET6 if passed a valid IP address, otherwise returns None. *)
let domain_of_addr str =
  try
    let addr = Unix.inet_addr_of_string str in
    Some (Unix.domain_of_sockaddr (Unix.ADDR_INET (addr, 1)))
  with _ -> None

let test_open_called = Atomic.make false

let test_open n =
  if not (Atomic.compare_and_set test_open_called false true) then
    invalid_arg "test_open can only be called once" ;
  (* we could make this conditional on whether ulimit was increased or not,
     but that could hide bugs if we think the CI has tested this, but due to ulimit it hasn't.
  *)
  if n > 0 then (
    let socket = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    at_exit (fun () -> Unix.close socket) ;
    for _ = 2 to n do
      let fd = Unix.dup socket in
      at_exit (fun () -> Unix.close fd)
    done
  )

(* --------------------------------------------------------------------------------------- *)

module Daemon = struct
  module State = struct
    type t =
      | Ready
      | Reloading
      | Stopping
      | Status of string
      | Error of Unix.error
      | Buserror of string
      | MainPID of int
      | Watchdog
  end

  let systemd_notify state =
    let open State in
    let ( let* ) = Option.bind in
    let msg_status =
      let* msg =
        match state with
        | Ready ->
            Some "READY=1"
        | Reloading ->
            Some "RELOADING=1"
        | Stopping ->
            Some "STOPPING=1"
        | Status s ->
            Some ("STATUS=" ^ s)
        | Error e ->
            Option.map
              (fun x -> "ERRNO=" ^ x)
              ( match Errno_unix.of_unix e with
              | h :: _ ->
                  Option.map
                    (fun x -> Signed.SInt.to_string x)
                    (Errno.to_code ~host:Errno_unix.host h)
              | [] ->
                  None
                  (* If empty, then couldn't map the Unix.error to an
                      integer - a requirement of systemd's protocol *)
              )
        | Buserror s ->
            Some ("BUSERROR=" ^ s)
        | MainPID i ->
            Some ("MAINPID=" ^ string_of_int i)
        | Watchdog ->
            Some "WATCHDOG=1"
      in
      let* env_socket = Sys.getenv_opt "NOTIFY_SOCKET" in
      (* If the variable is not set, the protocol is a noop *)
      let* socket_path =
        if String.starts_with ~prefix:"/" env_socket then
          Some env_socket
        else if String.starts_with ~prefix:"@" env_socket then
          Some ("\x00" ^ Astring.String.with_range ~first:1 env_socket)
        (* Handle abstract socket - replaces '@' with the null character *)
        else
          None
        (* Only AF_UNIX is supported, with path or abstract sockets *)
      in
      Unix.(
        let sock = socket PF_UNIX SOCK_DGRAM 0 ~cloexec:true in
        Xapi_stdext_pervasives.Pervasiveext.finally
          (fun _ ->
            let res =
              sendto_substring sock msg 0 (String.length msg) []
                (ADDR_UNIX socket_path)
            in
            if res >= 0 then Some () else None
          )
          (fun _ -> close sock)
      )
    in
    Option.is_some msg_status

  (** We test whether the runtime unit file directory has been
      created. Systemd guarantees this to happen very early
      during boot.
      Note: libsystemd uses faccessat instead to avoid following
      symlinks. It is not, however, present in the OCaml Unix module. *)
  let systemd_booted () =
    try
      Unix.(access "/run/systemd/system" [F_OK]) ;
      true
    with Unix.Unix_error _ -> false
end

let set_socket_timeout fd t =
  try Unix.(setsockopt_float fd SO_RCVTIMEO t)
  with Unix.Unix_error (Unix.ENOTSOCK, _, _) ->
    (* In the unit tests, the fd comes from a pipe... ignore *)
    ()

let with_socket_timeout fd timeout_opt f =
  match timeout_opt with
  | Some t ->
      if t < 1e-6 then invalid_arg (Printf.sprintf "Timeout too short: %g" t) ;
      let finally () = set_socket_timeout fd 0. in
      set_socket_timeout fd t ; Fun.protect ~finally f
  | None ->
      f ()
