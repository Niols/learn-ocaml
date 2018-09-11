(* This file is part of Learn-OCaml.
 *
 * Copyright (C) 2016 OCamlPro.
 *
 * Learn-OCaml is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * Learn-OCaml is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>. *)

open Learnocaml_data
open Learnocaml_store

let port = ref 8080

let cert_key_files = ref None

let log_channel = ref (Some stdout)

let args = Arg.align @@
  [ "-static-dir", Arg.Set_string static_dir,
    "PATH where static files should be found (./www)" ;
    "-sync-dir", Arg.Set_string sync_dir,
    "PATH where sync tokens are stored (./sync)" ;
    "-port", Arg.Set_int port,
    "PORT the TCP port (8080)" ]

open Lwt.Infix

let read_static_file path =
  let shorten path =
    let rec resolve acc = function
      | [] -> List.rev acc
      | "." :: rest -> resolve acc rest
      | ".." :: rest ->
          begin match acc with
            | [] -> resolve [] rest
            | _ :: acc -> resolve acc rest end
      | name :: rest -> resolve (name :: acc) rest in
    resolve [] path in
  let path =
    String.concat Filename.dir_sep (!static_dir :: shorten path) in
  Lwt_io.(with_file ~mode: Input path read)

exception Too_long_body

let string_of_stream ?(max_size = 1024 * 1024) s =
  let b = Buffer.create (64 * 1024) in
  let pos = ref 0 in
  let add_string s =
    pos := !pos + String.length s;
    if !pos > max_size then
      Lwt.fail Too_long_body
    else begin
      Buffer.add_string b s;
      Lwt.return_unit
    end
  in
  Lwt.catch begin function () ->
    Lwt_stream.iter_s add_string s >>= fun () ->
    Lwt.return (Some (Buffer.contents b))
  end begin function
    | Too_long_body -> Lwt.return None
    | e -> Lwt.fail e
  end

module Api = Learnocaml_api

open Cohttp_lwt_unix

type caching =
  | Nocache (* dynamic resources *)
  | Shortcache (* valid for the server lifetime *)
  | Longcache (* static resources *)

let respond_static path =
  Lwt.catch
    (fun () ->
       read_static_file path >|= fun body ->
       Ok (body,
           Magic_mime.lookup (List.fold_left (fun _ r -> r) "" path)))
    (fun e ->
       Lwt.return (Error (`Not_found, Printexc.to_string e)))

let respond_json = fun x ->
  Lwt.return (Ok (x, "application/json"))

let with_verified_teacher_token token cont =
  Token.check_teacher token >>= function
  | true -> cont ()
  | false -> Lwt.return (Error (`Forbidden, "Access restricted"))

let string_of_date ts =
  let open Unix in
  let tm = gmtime ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let log conn api_req =
  match !log_channel with
  | None -> ()
  | Some oc ->
      let src_addr = match conn with
        | Conduit_lwt_unix.TCP tcp, _ ->
            Ipaddr.to_string tcp.Conduit_lwt_unix.ip
        | _ -> ""
      in
      output_string oc (string_of_date (Unix.gettimeofday ()));
      output_char oc '\t';
      output_string oc src_addr;
      output_char oc '\t';
      output_string oc
        (match api_req.Api.meth with
         | `GET -> "GET "
         | `POST _ -> "POST");
      output_char oc '\t';
      output_char oc '/';
      output_string oc (String.concat "/" api_req.Api.path);
      (match api_req.Api.args with | [] -> () | l ->
          output_char oc '?';
          output_string oc
            (String.concat "&" (List.map (fun (a, b) -> a ^"="^ b) l)));
      output_char oc '\n';
      flush oc

let check_report exo report grade =
  let max_grade = Learnocaml_exercise.(access File.max_score) exo in
  let score, _ = Learnocaml_report.result report in
  score * 100 / max_grade = grade

module Request_handler = struct

  type 'a ret =
    ('a * string * caching, Cohttp.Code.status_code * string) result Lwt.t

  let map_ret f r =
    r >|= function
    | Ok (x, content_type, caching) -> Ok (f x, content_type, caching)
    | Error (code, msg) -> Error (code, msg)

  let token_save_mutexes = Hashtbl.create 223

  let callback_raw
    : type resp.
      resp Api.request ->
      (resp * string, Cohttp.Code.status_code * string) result Lwt.t
    = function
      | Api.Version () ->
          respond_json Api.version
      | Api.Static path ->
          respond_static path
      | Api.Create_token (None, nick) ->
          Token.create_student () >>= fun tok ->
          (match nick with None -> Lwt.return_unit | Some nickname ->
              Save.set tok Save.{empty with nickname}) >>= fun () ->
          respond_json tok
      | Api.Create_token (Some token, _nick) ->
          Lwt.catch
            (fun () -> Token.register token >>= fun () -> respond_json token)
            (function
              | Failure m -> Lwt.return (Error (`Bad_request, m))
              | exn ->
                  Lwt.return
                    (Error (`Internal_server_error, Printexc.to_string exn)))
      | Api.Create_teacher_token token ->
          with_verified_teacher_token token @@ fun () ->
          Token.create_teacher () >>= respond_json

      | Api.Fetch_save token ->
          Lwt.catch
            (fun () -> Save.get token >>= function
               | Some save -> respond_json save
               | None -> Lwt.return (Error (`Not_found, "token not found")))
          @@ fun exn ->
          Lwt.return
            (Error (`Internal_server_error, Printexc.to_string exn))
      | Api.Update_save (token, save) ->
          let save = Save.fix_mtimes save in
          let exercise_states = SMap.bindings save.Save.all_exercise_states in
          (Token.check_teacher token >>= function
            | true -> Lwt.return exercise_states
            | false ->
                Lwt_list.filter_s (fun (id, _) ->
                    Exercise.Status.is_open id token >|= function
                    | `Open -> true
                    | `Closed -> false
                    | `Deadline t -> t >= -300. (* Grace period! *))
                  exercise_states)
          >>= fun valid_exercise_states ->
          let save =
            { save with
              Save.all_exercise_states =
                List.fold_left (fun m (id,save) -> SMap.add id save m)
                  SMap.empty valid_exercise_states }
          in
          let key = (token :> Token.t) in
          let mutex =
            try Hashtbl.find token_save_mutexes key with Not_found ->
              let mut = Lwt_mutex.create () in
              Hashtbl.add token_save_mutexes key mut;
              mut
          in
          Lwt_mutex.with_lock mutex @@ fun () ->
          Lwt.finalize (fun () ->
              Save.get token >>= function
              | None ->
                  Lwt.return
                    (Error (`Not_found, Token.to_string token))
              | Some prev_save ->
                let save = Save.sync prev_save save in
                Save.set token save >>= fun () -> respond_json save)
            (fun () ->
               if Lwt_mutex.is_empty mutex
               then Hashtbl.remove token_save_mutexes key;
               Lwt.return_unit)

      | Api.Students_list token ->
          with_verified_teacher_token token @@ fun () ->
          Token.Index.get ()
          >|= List.filter Token.is_student
          >>= Lwt_list.map_p (fun token ->
              Lwt.catch (fun () -> Save.get token)
                (fun e ->
                   Format.eprintf "[ERROR] Corrupt save, cannot load %s: %s@."
                     (Token.to_string token)
                     (Printexc.to_string e);
                   Lwt.return_none)
              >>= function
              | None ->
                  Lwt.return Student.{
                      token;
                      nickname = None;
                      results = SMap.empty;
                      tags = [];
                    }
              | Some save ->
                  let nickname = match save.Save.nickname with
                    | "" -> None
                    | n -> Some n
                  in
                  let results =
                    SMap.map
                      (fun st -> Answer.(st.mtime, st.grade))
                      save.Save.all_exercise_states
                  in
                  let tags = [] in
                  Lwt.return Student.{token; nickname; results; tags})
          >>= respond_json
      | Api.Students_csv (token, exercises, students) ->
          with_verified_teacher_token token @@ fun () ->
          (match students with
           | [] -> Token.Index.get () >|= List.filter Token.is_student
           | l -> Lwt.return l)
          >>= Lwt_list.map_p (fun token ->
              Save.get token >|= fun save -> token, save)
          >>= fun tok_saves ->
          let all_exercises =
            match exercises with
            | [] ->
                List.fold_left (fun acc (_tok, save) ->
                    match save with
                    | None -> acc
                    | Some save ->
                        SMap.fold (fun ex_id _ans acc -> SSet.add ex_id acc)
                          save.Save.all_exercise_states
                          acc)
                  SSet.empty tok_saves
                |> SSet.elements
            | exercises -> exercises
          in
          let columns =
            "token" :: "nickname" ::
            (List.fold_left (fun acc ex_id ->
                 (ex_id ^ " date") ::
                 (ex_id ^ " grade") ::
                 acc)
                [] (List.rev all_exercises))
          in
          let buf = Buffer.create 3497 in
          let sep () = Buffer.add_char buf ',' in
          let line () = Buffer.add_char buf '\n' in
          Buffer.add_string buf (String.concat "," columns);
          line ();
          Lwt_list.iter_s (fun (tok, save) ->
              match save with None -> Lwt.return_unit | Some save ->
                Buffer.add_string buf (Token.to_string tok);
                sep ();
                Buffer.add_string buf save.Save.nickname;
                Lwt_list.iter_s (fun ex_id ->
                    Lwt.catch (fun () ->
                        sep ();
                        Exercise.get ex_id >>= fun exo ->
                        Lwt.wrap2 SMap.find ex_id save.Save.all_exercise_states
                        >|= fun st ->
                        (match st.Answer.grade with
                         | None -> ()
                         | Some grade ->
                             if match st.Answer.report with
                               | None -> false
                               | Some rep -> check_report exo rep grade
                             then Buffer.add_string buf (string_of_int grade)
                             else Printf.bprintf buf "CHEAT(%d)" grade);
                        sep ();
                        Buffer.add_string buf (string_of_date st.Answer.mtime))
                      (function
                        | Not_found -> sep (); Lwt.return_unit
                        | e -> raise e))
                  all_exercises
                >|= line)
            tok_saves
          >|= fun () -> Ok (Buffer.contents buf, "text/csv")

      | Api.Exercise_index token ->
          Exercise.Index.get () >>= fun index ->
          Token.check_teacher token >>= (function
              | true -> Lwt.return (index, [])
              | false ->
                  let deadlines = ref [] in
                  Exercise.Index.filterk
                    (fun id _ k ->
                       Exercise.Status.is_open id token >>= function
                       | `Open -> k true
                       | `Closed -> k false
                       | `Deadline t ->
                           deadlines := (id, max t 0.) :: !deadlines;
                           k true)
                    index (fun index -> Lwt.return (index, !deadlines)))
          >>= respond_json
      | Api.Exercise (token, id) ->
          (Exercise.Status.is_open id token >>= function
          | `Open | `Deadline _ as o ->
              Exercise.Meta.get id >>= fun meta ->
              Exercise.get id >>= fun ex ->
              respond_json
                (meta, ex,
                 match o with `Deadline t -> Some (max t 0.) | `Open -> None)
          | `Closed ->
              Lwt.return (Error (`Forbidden, "Exercise closed")))

      | Api.Lesson_index () ->
          Lesson.Index.get () >>= respond_json
      | Api.Lesson id ->
          Lesson.get id >>= respond_json

      | Api.Tutorial_index () ->
          Tutorial.Index.get () >>= respond_json
      | Api.Tutorial id ->
          Tutorial.get id >>= respond_json

      | Api.Focused_skills_index () ->
          Exercise.Skill.get_focus_index () >>= respond_json
      | Api.Focusing_skill s ->
          Exercise.Skill.get_focused s >>= respond_json

      | Api.Required_skills_index () ->
          Exercise.Skill.get_requirements_index () >>= respond_json
      | Api.Requiring_skill s ->
          Exercise.Skill.get_required s >>= respond_json

      | Api.Exercise_status_index token ->
          with_verified_teacher_token token @@ fun () ->
          Exercise.Status.all () >>= respond_json
      | Api.Exercise_status (token, id) ->
          with_verified_teacher_token token @@ fun () ->
          Exercise.Status.get id >>= respond_json
      | Api.Set_exercise_status (token, status) ->
          with_verified_teacher_token token @@ fun () ->
          Lwt_list.iter_s
            Exercise.Status.(fun (ancestor, ours) ->
                get ancestor.id >>= fun theirs ->
                set (three_way_merge ~ancestor ~theirs ~ours))
            status
          >>= respond_json

      | Api.Invalid_request s ->
          Lwt.return (Error (`Bad_request, s))

  let caching: type resp. resp Api.request -> caching = function
    | Api.Version () -> Shortcache
    | Api.Static ("fonts"::_ | "icons"::_ | "js"::_::_::_) -> Longcache
    | Api.Static ("css"::_ | "js"::_ | _) -> Shortcache

    | Api.Exercise _ -> Shortcache

    | Api.Lesson_index _ -> Shortcache
    | Api.Lesson _ -> Shortcache
    | Api.Tutorial_index _ -> Shortcache
    | Api.Tutorial _ -> Shortcache

    | _ -> Nocache

  let callback: type resp. resp Api.request -> resp ret = fun req ->
    let cache = caching req in
    Lwt.catch (fun () -> callback_raw req)
      (function
        | Not_found -> Lwt.return (Error (`Not_found,"Exercise not found"))
        | e -> raise e)
    >|= function
    | Ok (resp, content_type) -> Ok (resp, content_type, cache)
    | Error e -> Error e

end

module Api_server = Api.Server (Json_codec) (Request_handler)

let init_teacher_token () =
  Token.Index.get () >>= function tokens ->
    match List.filter Token.is_teacher tokens with
    | [] ->
        Token.create_teacher () >|= fun token ->
        Printf.printf "Initial teacher token created: %s\n%!"
          (Token.to_string token)
    | teachers ->
        Printf.printf "Found the following teacher tokens:\n  - %s\n%!"
          (String.concat "\n  - " (List.map Token.to_string teachers));
        Lwt.return_unit

let last_modified = (* server startup time *)
  let open Unix in
  let tm = gmtime (gettimeofday ()) in
  Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT"
    (match tm.tm_wday with
     | 0 -> "Sun" | 1 -> "Mon" | 2 -> "Tue" | 3 -> "Wed"
     | 4 -> "Thu" | 5 -> "Fri" | 6 -> "Sat"
     | _ -> assert false)
    tm.tm_mday
    (match tm.tm_mon with
     | 0 -> "Jan" | 1 -> "Feb" | 2 -> "Mar" | 3 -> "Apr" | 4 -> "May"
     | 5 -> "Jun" | 6 -> "Jul" | 7 -> "Aug" | 8 -> "Sep" | 9 -> "Oct"
     | 10 -> "Nov" | 11 -> "Dec" | _ -> assert false)
    (tm.tm_year + 1900)
    tm.tm_hour tm.tm_min tm.tm_sec

(* Taken from the source of "decompress", from bin/easy.ml *)
let compress =
  let input_buffer = Bytes.create 0xFFFF in
  let output_buffer = Bytes.create 0xFFFF in

  fun ?(level = 4) data ->
  let pos = ref 0 in
  let res = Buffer.create (String.length data) in

  Decompress.Zlib_deflate.bytes
    input_buffer output_buffer
    (fun input_buffer -> function
     | Some max ->
       let n = min max (min 0xFFFF (String.length data - !pos)) in
       Bytes.blit_string data !pos input_buffer 0 n;
       pos := !pos + n;
       n
     | None ->
       let n = min 0xFFFF (String.length data - !pos) in
       Bytes.blit_string data !pos input_buffer 0 n;
       pos := !pos + n;
       n)
    (fun output_buffer len ->
      Buffer.add_subbytes res output_buffer 0 len;
      0xFFFF)
    (Decompress.Zlib_deflate.default ~proof:Decompress.B.proof_bytes level)
  (* We can specify the level of the compression, see the documentation to know
     what we use for each level. The default is 4.
  *)
  |> function
  | Ok _ -> Buffer.contents res
  | Error _ -> failwith "Could not compress"

let launch () =
  (* Learnocaml_store.init ~exercise_index:
   *   (String.concat Filename.dir_sep
   *      (!static_dir :: Learnocaml_index.exercise_index_path)); *)
  let callback conn req body =
    let uri = Request.uri req in
    let path = Uri.path uri in
    let path = Stringext.split ~on:'/' path in
    let path = List.filter ((<>) "") path in
    let query = Uri.query uri in
    let args = List.map (fun (s, l) -> s, String.concat "," l) query in
    let use_compression =
      List.exists (function _, Cohttp.Accept.Deflate -> true | _ -> false)
        (Cohttp.Header.get_acceptable_encodings req.Request.headers)
    in
    (* let cookies = Cohttp.Cookie.Cookie_hdr.extract (Cohttp.Request.headers req) in *)
    let respond = function
      | Error (status, body) ->
          Server.respond_error ~status ~body ()
      | Ok (str, content_type, caching) ->
          let headers = Cohttp.Header.init_with "Content-Type" content_type in
          let headers = match caching with
            | Longcache ->
                Cohttp.Header.add headers
                  "Cache-Control" "public, immutable, max-age=2592000"
                  (* 1 month *)
            | Shortcache ->
                Cohttp.Header.add_list headers [
                  "Last-Modified", last_modified;
                  "Cache-Control", "private, must-revalidate";
                ]
            | Nocache ->
                Cohttp.Header.add headers "Cache-Control" "no-cache"
          in
          match
            if use_compression && String.length str >= 1024 &&
               match String.split_on_char '/' content_type with
               | "text"::_
               | "application" :: ("javascript" | "json") :: _
               | "image" :: ("gif" | "svg+xml") :: _ -> true
               | _ -> false
            then
              Cohttp.Header.add headers "Content-Encoding" "deflate",
              compress str
            else headers, str
          with
          | headers, str ->
              Server.respond_string ~headers ~status:`OK ~body:str ()
          | exception e ->
              Server.respond_error ~status:`Internal_server_error
                ~body:(Printexc.to_string e) ()
    in
    if Cohttp.Header.get req.Request.headers "If-Modified-Since" =
       Some last_modified
    then Server.respond ~status:`Not_modified ~body:Cohttp_lwt.Body.empty ()
    else
    (match req.Request.meth with
     | `GET -> Lwt.return (Ok {Api.meth = `GET; path; args})
     | `POST ->
         (string_of_stream (Cohttp_lwt.Body.to_stream body) >|= function
           | Some s -> Ok {Api.meth = `POST s; path; args}
           | None -> Error (`Bad_request, "Missing POST body"))
     | _ -> Lwt.return (Error (`Bad_request, "Unsupported method")))
    >>= (function
        | Ok req ->
            log conn req;
            Api_server.handler req
        | Error e -> Lwt.return (Error e))
    >>=
    respond
  in
  let mode =
    match !cert_key_files with
    | None -> (`TCP (`Port !port))
    | Some (crt, key) ->
        `TLS (`Crt_file_path crt, `Key_file_path key, `No_password, `Port !port)
  in
  Random.self_init () ;
  init_teacher_token () >>= fun () ->
  Lwt.catch (fun () ->
      Server.create
        ~on_exn: (function
            | Unix.Unix_error(Unix.EPIPE, "write", "") -> ()
            | exn -> raise exn)
        ~mode (Server.make ~callback ()) >>= fun () ->
      Lwt.return true)
  @@ function
  | Sys.Break ->
      Lwt.return true
  | Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
      Printf.eprintf
        "Could not bind port %d, another instance may still be running?\n%!"
        !port;
      Lwt.return false
  | e ->
      Printf.eprintf "Server error: %s\n%!" (Printexc.to_string e);
      Lwt.return false
