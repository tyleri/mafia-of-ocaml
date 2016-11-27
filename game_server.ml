open Core.Std
open Async.Std
open Cohttp_async 

open Data 
open Game 
open Ringbuffer

type lobby_state = {
    admin : string;
    players : (string * bool) list; 
}

type server_state = 
   | Lobby of lobby_state 
   | Game of game_state  

type room_data = {
    state: server_state; 
    chat_buffer: (timestamp * string * string) list;
    action_buffer: (timestamp * client_json) list;
}

type action_bundle = {id: string; rd: room_data; cd: client_json}
exception Action_Error of (Server.response Deferred.t) 

let rooms = String.Table.create () 

(* [respond code msg] is an alias for Server.respond_with_string *)
let respond code msg = Server.respond_with_string ~code:code msg 

(* [extract_id req] returns the value of the query 
 * param "room_id" if it is present and well formed.
 * Requires: query param is in form /?room_id={x}
 * Returns: Some x if well formed, None otherwise)
 *) 

let extract_id req = 
    let uri = Cohttp.Request.uri req in 
    Uri.get_query_param uri "room_id"

(* room creation logic *)
(* TODO: Rewrite Using Exceptions *)
(* -------------------------------------------------------- *)

(* [room_op req op] passes the room information matching the room_id in [req]
 * to [op] if it exists. Returns Bad_Request if the room_id is malformed 
 * or the room doesn't exist.*)

let room_op req op =
    let id = extract_id req in 
    match id with 
        | None -> 
            respond `Bad_request "Malformed room_id."
        | Some s when not (Hashtbl.mem rooms s) -> 
            respond `Bad_request "Room doesn't exist."
        | Some s ->
            let room_data = Hashtbl.find_exn rooms s in op s room_data 

let create_room conn req body = 
    let id = extract_id req in
    match id with 
        | None -> 
            respond`Bad_request "Malformed room_id" 
        | Some s when Hashtbl.mem rooms s -> 
            respond`Bad_request "Room already exists." 
        | Some s -> 
            let room = {
                state = Lobby {admin = ""; players = []};
                chat_buffer = [];
                action_buffer = []; 
            } in 
            Hashtbl.replace rooms s room; 
            Server.respond_with_string  ~code:`OK "Room created."


let join_room conn req body = 
    let add_player s l =  
        let in_use = List.fold ~init:false ~f:(fun acc (n,_) -> (n = s) || acc) l.players in 
        let too_long = String.length s >= 20 in 

        if (in_use || too_long) then None 
        else if l.players = [] then 
            Some {l with admin = s; players = [(s,true)]}
        else 
            Some {l with players = (s,false)::l.players}
    in 

    let join body = 
        try 
            let cd = decode_cjson body in 
            let lobby_op id rd = 
                match rd.state with 
                    | Game _ ->
                        respond `Bad_request "Game already in progress."
                    | Lobby l ->
                    let result = add_player (cd.player_id) (l) in 
                    (match result with 
                        | None -> 
                            respond `Bad_request  "player_id in use."
                        | Some l' ->
                            Hashtbl.replace rooms id {rd with state = Lobby l'}; 
                            respond `OK "Joined!")  
            in 
            room_op (req) (lobby_op)
        with _ -> respond `Bad_request "Malformed client_action.json"

    in 

    Body.to_string body >>= join 
(* -------------------------------------------------------- *)

(* [load_room req cd] returns an action_bundle using the room_id located within
 * the query paramaters of [req]. 
 * Requires: 
 *  - room_id is well formed and registered, Action_Error otherwise *)

let load_room req cd = 
    let id = extract_id req in 
    match id with 
        | None -> 
            raise (Action_Error (respond `Bad_request "Malformed room_id."))
        | Some s when not (Hashtbl.mem rooms s) -> 
            raise (Action_Error (respond `Bad_request "Room doesn't exist."))
        | Some s ->
            let room_data = Hashtbl.find_exn rooms s in {id = s; rd = room_data; cd = cd}

(* [in_room ab] is [ab] if the player specified in the action bundle's client data 
 * is within the room specified in the action bundle's room_data. 
 * Returns Action_Error otherwise. *)

let in_room ab =
    let {id; rd; cd} = ab in 
    let pn = cd.player_id in 
    let in_room = match rd.state with 
                    | Lobby ls ->
                        List.fold ~init:false ~f:(fun acc (n,_) -> (pn = n) || acc) ls.players
                    | Game gs -> 
                        List.fold ~init:false ~f:(fun acc (n,_) -> (pn = n) || acc) gs.players
    in

    if in_room then ab
    else 
        raise (Action_Error (respond `Bad_request (pn ^ " is not in room " ^ id)))

(* [can_chat ab] is [ab] if the player specified in the action bundle's client_data 
 * is able to chat in the supplied room. Returns Action Error otherwise *)

let can_chat ab = 
    let {id; rd; cd} = ab in 
    let pn = cd.player_id in 
    let can_chat = match rd.state with 
                    | Lobby ls -> true 
                    | Game gs -> 
                        (* check if the player is alive *)
                        (* check if we can chat in this game state *)
                        failwith "unimplemented" 
    in 

    if can_chat then ab 
    else 
        raise (Action_Error (respond`Bad_request "Cannot Currently Chat"))

(* [write_chat ab] adds the client's chat message into the chat buffer and 
 * returns an 'OK response *)

let write_chat {id; rd; cd} = 
    let pn = cd.player_id in 
    let msg = List.fold ~init:"" ~f:(^) cd.arguments in 
    let addition = ((Time.now ()), pn, msg) in 
    Hashtbl.set rooms id {rd with chat_buffer = (addition :: rd.chat_buffer)};
    respond `OK "Done."

(* [write_ready ab] toggles the player's ready state given the client_data and 
 * room_data within the supplied action_bundle. 
 * Requires: the room within [ab] is in lobby mode. *)

let write_ready {id; rd; cd} = 
    let update_players acc (n,s) = 
        if n = cd.player_id then (n,true)::acc 
                            else (n,s)::acc 
    in 
    
    match rd.state with 
        | Game _ -> raise (Action_Error (respond`Bad_request "Cannot Ready in Game."))
        | Lobby ls ->
            let pl' = List.fold ~init:[] ~f:update_players ls.players in 
            Hashtbl.set rooms id {rd with state = Lobby {ls with players = pl'}}; 
            respond `OK "Done."

(* [is_admin ab] is [ab] if the palyer specified within the action_bundle is an 
 * admin in the action_bundle's supplied room, and the room is in lobby mode. 
 * Returns Action_Error otherwise. *)

let is_admin ab = 
    let {id; rd; cd} = ab in
    match rd.state with 
        | Game _ -> raise (Action_Error (respond`Bad_request "Cannot be Admin in Game"))
        | Lobby ls ->
            if ls.admin = cd.player_id then ab 
            else 
                 raise (Action_Error (respond`Bad_request "Player is not admin."))

(* [all_ready ab] is [ab] if all the players in the room specified by [ab] are 
 * have readied up, and the room is in lobby mode. Returns Action_Error otherwise *)

let all_ready ab =
     let {id; rd; cd} = ab in 

     let check_ready acc (_,ready) = acc && ready in 

     match rd.state with 
        | Game _ -> raise (Action_Error (respond`Bad_request "Players Already in Game"))
        | Lobby ls -> 
            let ready = List.fold ~init:false ~f:check_ready ls.players in 
            if ready then ab 
            else 
                raise (Action_Error (respond`Bad_request "Not all players are ready."))

(* [write_game ab] moves a game from lobby mode into game mode, and launches the 
 * associated game_state daemons. Requires: Room is in Lobby Mode *)

let write_game ab = 
    let {id; rd; cd} = ab in 
    match rd.state with 
        | Game _ -> raise (Action_Error (respond`Bad_request "Game already in progress"))
        | Lobby ls ->
            let players = List.fold ~init:[] ~f:(fun acc (pn,_) -> pn :: acc) ls.players in 
            let gs = Game.init_state players in
            (* TODO: Launch Room Refresh Daemon *) 
            Hashtbl.set rooms id {rd with state = Game gs}; 
            respond `OK "Done."

(* [can_vote ab] is [ab] if the player specified within [ab] can vote in the current 
 * game_state. Returns Action_Error otherwise *)

let can_vote ab = 
    failwith "unimplemented"

(* [write_vote ab] adds the vote specified within the client data of the action buffer 
 * to the room's action_queue. Requires that the room is in game mode. *)

let write_vote ab = 
    let {id; rd; cd} = ab in 
    match rd.state with 
        | Lobby _ -> raise (Action_Error (respond `Bad_request "Cannot vote in Lobby"))
        | Game gs ->
            let actbuf' = (Time.now (), cd) :: rd.action_buffer in 
            Hashtbl.set rooms id {rd with action_buffer = actbuf'};  
            respond `OK "Done."

let player_action conn req body = 
    let action body = 
        try 
            let cd = decode_cjson body in
            let ab = load_room req cd |> in_room in  
            match cd.player_action with 
                | "chat" -> ab |> can_chat |> write_chat 
                | "ready" -> ab |> write_ready  
                | "start" -> ab |> is_admin |> all_ready |> write_game 
                | "vote" -> ab |> can_vote |> write_vote 
                | _ -> respond `Bad_request "Invalid Command"
        with 
            | Action_Error response -> response  
            | _ -> respond `Bad_request "Malformed client_action.json"
    in

    Body.to_string body >>= action

let room_status conn req body = 
    failwith "unimplemented"

let handler ~body:body conn req =
    let uri = Cohttp.Request.uri req in 
    let verb = Cohttp.Request.meth req in 
    match Uri.path uri, verb with
        | "/create_room", `POST -> create_room conn req body
        | "/join_room", `POST ->  join_room conn req body 
        | "/player_action", `POST -> player_action conn req body
        | "/room_status", `GET -> room_status conn req body 
        | _ , _ ->
            respond`Not_found "Invalid Route."

let start_server port () = 
    eprintf "Starting mafia_of_ocaml...\n"; 
    eprintf "~-~-~-~-~-~-~~-~-~-~-~-~-~~-~-~-~-~-~-~~-~-~-~-~-~-~\n";
    eprintf "Listening for HTTP on port %d\n" port; 
    Cohttp_async.Server.create ~on_handler_error:`Raise 
        (Tcp.on_port port) handler
    >>= fun _ -> Deferred.never ()

let () = 
    Command.async
        ~summary: "Start a hello world Async Server"
        Command.Spec.(empty +> 
            flag "-p" (optional_with_default 3110 int)
                ~doc: "int Source port to listen on"
            ) start_server 
        |> Command.run 