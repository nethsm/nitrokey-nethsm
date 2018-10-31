open Lwt.Infix
open Sexplib.Std

module Make (KV_Maker: S.KV_Maker) = struct

module Priv = struct
  type data =
    | Rsa of Nocrypto.Rsa.priv
    [@@deriving sexp]
  type t = {
    purpose: string;
    data: data;
  } [@@deriving sexp]
end

exception Failure_exn of Yojson.Basic.json

type 'a result =
  | Ok of 'a
  | Failure of Yojson.Basic.json

module YB = Yojson.Basic

module Pub = struct
  type data =
    | Rsa of Nocrypto.Rsa.pub
  type t = {
    purpose: string;
    data: data;
  }
end

type pub = Pub.t

module Padding = struct
  type t =
    | None
    | PKCS1
    | OAEP of Nocrypto.Hash.hash
    | PSS of Nocrypto.Hash.hash
end

(* helper functions *)

(* let failwith json:YB.json =
  raise (Failure_exn json) *)

let failwith_desc desc =
  raise (Failure_exn (`Assoc [
    ("description", `String desc)
  ]))

let failwith_missing keys =
  let l = List.map (fun x -> `String x) keys in
  raise (Failure_exn (`Assoc [
    ("description", `String "JSON keys are missing");
    ("missing", `List l)
  ]))

let rem_opt = function
  | Some x -> x
  | None -> assert false

let pub_of_priv { Priv.purpose; data } =
  let data = match data with
    | Priv.Rsa d -> Pub.Rsa (Nocrypto.Rsa.pub_of_priv d)
  in
  { Pub.purpose; data }

(* let trim_tail s =
  let rec f n = if n>=0 && s.[n]='\000' then f (pred n) else n in
  let len = String.length s |> pred |> f |> succ in
  String.sub s 0 len *)

let b64_encode = B64.encode ~alphabet:B64.uri_safe_alphabet

let b64_decode = B64.decode ~alphabet:B64.uri_safe_alphabet

let b64_of_z z =
  b64_encode (Cstruct.to_string (Nocrypto.Numeric.Z.to_cstruct_be z))

let z_of_b64 s =
  Nocrypto.Numeric.Z.of_cstruct_be (Cstruct.of_string (b64_decode s))

(* let pq_of_ned n e d =
  let open Z in
  let de = e*d in
  let modplus1 = n + one in
  let deminus1 = de - one in
  let kprima = de/n in
  let ks = [kprima; kprima + one; kprima - one] in
  let rec f = function
    | [] -> assert false
    | k :: rest -> let fi = deminus1 / k in
      let pplusq = modplus1 - fi in
      let delta = pplusq*pplusq - n*(of_int 4) in
      let sqr = sqrt delta in
      let p = (pplusq + sqr)/(of_int 2) in
      if (n mod p) = Z.zero && p > zero
        then let q = (pplusq - sqr)/(of_int 2) in
          (p, q)
        else f rest
  in
  f ks *)

let string_of_json_key json key =
  try
    YB.Util.member key json |> YB.Util.to_string
  with
    YB.Util.Type_error _ -> failwith_missing [key]

let rsa_priv_of_json json =
  let e = string_of_json_key json "publicExponent" |> z_of_b64 in
  let p = string_of_json_key json "primeP" |> z_of_b64 in
  let q = string_of_json_key json "primeQ" |> z_of_b64 in
  Priv.Rsa (Nocrypto.Rsa.priv_of_primes ~e ~p ~q)

let priv_of_json json =
  let id =
    try
      Some (YB.Util.member "id" json |> YB.Util.to_string)
    with
      YB.Util.Type_error _ -> None
  in
  let purpose = string_of_json_key json "purpose" in
  let algorithm = string_of_json_key json "algorithm" in
  let data_json = YB.Util.member "privateKey" json in
  let length =
    try
      Some (YB.Util.member "length" json |> YB.Util.to_int)
    with
      YB.Util.Type_error _ -> None
  in
  let data = match (algorithm, data_json, length) with
    | ("RSA", (`Assoc _ as j), None) -> rsa_priv_of_json j
    | ("RSA", `Null, Some l) -> Priv.Rsa (Nocrypto.Rsa.generate l)
    | ("RSA", _, _) -> failwith_missing ["privateKey"; "length"]
    | _ -> failwith_desc ("Unknown key type: " ^ algorithm)
  in
  id, { Priv.purpose; data }

(* let priv_of_pem s =
  Cstruct.of_string s |> X509.Encoding.Pem.Private_key.of_pem_cstruct1
    |> function `RSA key -> key *)


module Db = KV_Maker(Priv)

(******************** public functions ********************)

let pem_of_pub { Pub.data ; _ } =
  let Pub.Rsa k = data in
  `RSA k |> X509.Encoding.Pem.Public_key.to_pem_cstruct1 |> Cstruct.to_string

let json_of_pub id { Pub.purpose; data } =
  let json_hd = [
    ("id", `String id);
    ("purpose", `String purpose);
    ]
  in
  let json_data = match data with
    | Pub.Rsa { Nocrypto.Rsa.e; n} -> [
      ("algorithm", `String "RSA");
      ("publicKey", `Assoc [
        ("modulus", `String (b64_of_z n));
        ("publicExponent", `String (b64_of_z e));
        ])
      ]
  in
  `Assoc (json_hd @ json_data)

let add ~key =
  Lwt.catch (fun () ->
    Lwt.wrap1 priv_of_json key
    >>= (fun (id, k) ->
      Db.add id k
    )
    >|= (fun x ->
      Ok x
    )
  )(function
    | Failure_exn json -> Lwt.return (Failure json)
    | e -> Lwt.fail e
  )

let put ~id ~key =
  Lwt.catch (fun () ->
    Lwt.wrap1 priv_of_json key
    >>= (fun (_, k) ->
      Db.put id k
    )
    >|= (fun x ->
      Ok x
    )
  )(function
    | Failure_exn json -> Lwt.return (Failure json)
    | e -> Lwt.fail e
  )

let del ~id = Db.delete id

let get ~id = Db.get id >|= function
  | None -> None
  | Some k -> Some (pub_of_priv k)

let get_all = Db.get_all

let decrypt ~id ~padding ~data =
  Db.get id
  >>= Lwt.wrap1 rem_opt
  >>= Lwt.wrap1 @@ fun key ->
  try
    let encrypted =
      try
        let decoded = YB.Util.member "encrypted" data
          |> YB.Util.to_string
          |> b64_decode
        in
        Cstruct.of_string decoded
      with
        | YB.Util.Type_error _
          -> failwith_missing ["encrypted"]
    in
    let decrypted_opt =
      try match (key, padding) with
      | ({ Priv.data=(Priv.Rsa key); _ }, Padding.None)
        -> Some (Nocrypto.Rsa.decrypt ~key ~mask:`Yes encrypted)
      | ({ Priv.data=(Priv.Rsa key); _ }, Padding.PKCS1)
        -> Nocrypto.Rsa.PKCS1.decrypt ~key ~mask:`Yes encrypted
      | ({ Priv.data=(Priv.Rsa key); _ }, Padding.OAEP h) ->
        let module H = (val (Nocrypto.Hash.module_of h)) in
        let module OAEP = (Nocrypto.Rsa.OAEP(H)) in
        OAEP.decrypt ~key ~mask:`Yes encrypted
      | ({ Priv.data=(Priv.Rsa _); _ }, Padding.PSS _)
        -> failwith_desc "PSS padding not available for decryption"
      with Nocrypto.Rsa.Insufficient_key
        -> failwith_desc "insufficient key for message"
    in
    match decrypted_opt with
      | Some decrypted ->
        let decrypted_b64 = b64_encode (Cstruct.to_string decrypted) in
        Ok (`Assoc [
          ("decrypted", `String decrypted_b64)
        ])
      | None -> failwith_desc "decryption failed"
  with
    | Failure_exn json -> Failure json


let sign ~id ~padding ~data =
  Db.get id
  >>= Lwt.wrap1 rem_opt
  >>= Lwt.wrap1 @@ fun key ->
  try
    let message =
      try
        let decoded = YB.Util.member "message" data
          |> YB.Util.to_string
          |> b64_decode
        in
        Cstruct.of_string decoded
      with
        | YB.Util.Type_error _
          -> failwith_missing ["message"]
    in
    let signed =
      try match (key, padding) with
      | ({ Priv.data=(Priv.Rsa key); _ }, Padding.PKCS1) ->
        Nocrypto.Rsa.PKCS1.sig_encode ~key ~mask:`Yes message
      | ({ Priv.data=(Priv.Rsa key); _ }, Padding.PSS h) ->
        let module H = (val (Nocrypto.Hash.module_of h)) in
        let module PSS = (Nocrypto.Rsa.PSS(H)) in
        PSS.sign ~key message
      | ({ Priv.data=(Priv.Rsa _); _ }, Padding.OAEP _)
        -> failwith_desc "OAEP padding not available for signing"
      | (_, Padding.None)
        -> failwith_desc "padding required for signing"
      with Nocrypto.Rsa.Insufficient_key
        -> failwith_desc "insufficient key for message"
    in
    let signed_b64 = b64_encode (Cstruct.to_string signed) in
      Ok (`Assoc ["signedMessage", `String signed_b64])
  with
    | Failure_exn json -> Failure json

end (*Make*)
