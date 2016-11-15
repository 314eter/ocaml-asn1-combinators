(* Copyright (c) 2014-2016 David Kaloper Meršinjak. All rights reserved.
   See LICENSE.md. *)

open Asn_core

module Writer = Asn_writer

module type Prim = sig
  type t
  val of_cstruct : Cstruct.t -> t
  val to_writer  : t -> Writer.t
  val random     : unit -> t
end

module type String_primitive = sig
  include Prim
  val random : ?size:int -> unit -> t
  val concat : t list -> t
  val length : t -> int
end

let rec replicate_l n f =
  if n < 1 then [] else f () :: replicate_l (pred n) f

let max_r_int = (1 lsl 30) - 1

let random_int () = Random.int max_r_int

let random_int_r a b = a + Random.int (b - a)

let random_size = function
  | Some size -> size
  | None      -> Random.int 20

let random_string ?size ~chars:(lo, hi) =
  String.init (random_size size)
    (fun _ -> Char.chr (random_int_r lo hi))

module Int64 = struct

  include Int64

  let ( + )  = add
  and ( - )  = sub
  and ( * )  = mul
  and ( / )  = div
  and (lsl)  = shift_left
  and (lsr)  = shift_right_logical
  and (asr)  = shift_right
  and (lor)  = logor
  and (land) = logand

  let max_p_int = Int64.of_int Pervasives.max_int

  let to_nat_checked i64 =
    if i64 < 0L || i64 > max_int then None else Some (to_int i64)

end

module Boolean : Prim with type t = bool = struct

  type t = bool

  let of_cstruct cs =
    if cs.Cstruct.len = 1 then
      (* XXX DER check *)
      Cstruct.get_uint8 cs 0 <> 0x00
    else parse_error "BOOLEAN: %a" pp_cs cs

  let to_writer b = Writer.of_byte (if b then 0xff else 0x00)

  let random = Random.bool
end

module Null : Prim with type t = unit = struct

  type t = unit

  let of_cstruct cs = if cs.Cstruct.len <> 0 then
    parse_error "NULL: %a" pp_cs cs

  let to_writer () = Writer.empty

  let random () = ()
end

module Integer : Prim with type t = Z.t = struct

  type t = Z.t

  let of_cstruct cs =
    let open Cstruct in
    (* XXX -> N-1 byte shifts?? *)
    let rec loop acc i = function
      | n when n >= 8 ->
          let x = BE.get_uint64 cs i in
          let x = Z.of_int64 Int64.(shift_right_logical x 8) in
          loop Z.(x lor (acc lsl 56)) (i + 7) (n - 7)
      | 4|5|6|7 as n ->
          let x = BE.get_uint32 cs i in
          let x = Z.of_int32 Int32.(shift_right_logical x 8) in
          loop Z.(x lor (acc lsl 24)) (i + 3) (n - 3)
      | 2|3 as n ->
          let x = Z.of_int (BE.get_uint16 cs i) in
          loop Z.(x lor (acc lsl 16)) (i + 2) (n - 2)
      | 1 ->
          let x = Z.of_int (get_uint8 cs i) in
          Z.(x lor (acc lsl 8))
      | _ -> acc
    in
    let n = cs.Cstruct.len in
    let x = loop Z.zero 0 n in
    match (Cstruct.get_uint8 cs 0) land 0x80 with
    | 0 -> x
    | _ -> let off = n * 8 in Z.(x - pow (of_int 2) off)

  let last8 z = Z.(extract z 0 8 |> to_int)

  let to_writer n =
    let sz  = Z.size n * 8 + 1 in
    let sz1 = sz - 1 in
    let cs  = Cstruct.create sz in

    let rec write i n =
      if n = Z.(~$(-1)) || n = Z.zero then i else
        ( Cstruct.set_uint8 cs i (last8 n) ;
          write (pred i) Z.(n asr 8) ) in

    let (bad_b0, padding) =
      if n >= Z.zero then ((<=) 0x80, 0x00)
      else ((>) 0x80, 0xff) in
    let off =
      let i = write sz1 n in
      if i = sz1 || bad_b0 (Cstruct.get_uint8 cs (succ i)) then
        ( Cstruct.set_uint8 cs i padding ; i )
      else succ i in
    Writer.of_cstruct Cstruct.(sub cs off (sz - off))


  let random () = Z.of_int (Random.int max_r_int - max_r_int / 2)

end

module Gen_string : String_primitive with type t = string = struct

  type t = string

  let of_cstruct = Cstruct.to_string

  let to_writer = Writer.of_string

  let random ?size () =
    random_string ?size ~chars:(32, 127)

  let (concat, length) = String.(concat "", length)
end

module Octets : String_primitive with type t = Cstruct.t = struct

  type t = Cstruct.t

  let of_cstruct { Cstruct.buffer; off; len } =
    (* XXX Mumbo jumbo to retain cs equality. *)
    Cstruct.of_bigarray @@ Bigarray.Array1.sub buffer off len

  let to_writer = Writer.of_cstruct

  let random ?size () =
    random_string ?size ~chars:(0, 256) |> Cstruct.of_string

  let concat = Cstruct.concat

  let length = Cstruct.len

end

module Bits : sig

  include String_primitive with type t = bits

  val to_array : t -> bool array
  val of_array : bool array -> t

end =
struct

  type t = int * Cstruct.t

  let of_cstruct cs =
    if Cstruct.len cs = 0 then parse_error "BITS: length 0" else
      let unused = Cstruct.get_uint8 cs 0
      and octets = Octets.of_cstruct (Cstruct.shift cs 1) in
      (unused, octets)

  let to_writer (unused, cs) =
    let size = Cstruct.len cs in
    let write off cs' =
      Cstruct.set_uint8 cs' off unused;
      Cstruct.blit cs 0 cs' (off + 1) size in
    Writer.immediate (size + 1) write


  let to_array (unused, cs) =
    Array.init (Cstruct.len cs * 8 - unused) @@ fun i ->
      let byte = (Cstruct.get_uint8 cs (i / 8)) lsl (i mod 8) in
      byte land 0x80 = 0x80

  let (|<) n = function
    | true  -> (n lsl 1) lor 1
    | false -> (n lsl 1)

  let of_array arr =
    let cs = Cstruct.create ((Array.length arr + 7) / 8) in
    match
      Array.fold_left
        (fun (n, acc, i) bit ->
          if n = 8 then
            ( Cstruct.set_uint8 cs i acc ; (1, 0 |< bit, i + 1) )
          else (n + 1, acc |< bit, i))
        (0, 0, 0)
        arr
    with
    | (0, _acc, _) -> (0, cs)
    | (n, acc, i) ->
        Cstruct.set_uint8 cs i (acc lsl (8 - n));
        (8 - n, cs)

  let random ?size () = (0, Octets.random ?size ())

  let concat css =
    let (unused, css') =
      let rec go = function
        | []           -> (0, [])
        | [(u, cs)]    -> (u, [cs])
        | (_, cs)::ucs -> let (u, css') = go ucs in (u, cs::css') in
      go css in
    (unused, Cstruct.concat css')

  and length (unused, cs) = Cstruct.len cs - unused

end

module OID = struct

  open Asn_oid

  (* XXX bounds-checks instead of exns *)
  let of_cstruct cs =
    let open Cstruct in

    let rec values i =
      if i = len cs then []
      else let (i, v) = component 0L i 0 in v :: values i

    and component acc off = function
      | 8 -> parse_error "OID: component too large: %a" pp_cs cs
      | i ->
          let b   = get_uint8 cs (off + i) in
          let b7  = b land 0x7f in
          let acc = Int64.(acc lor (of_int b7)) in
          if b land 0x80 = 0 then
            match Int64.to_nat_checked acc with
            | None   -> parse_error "OID: component out of int range: %Ld at %a"
                                    acc pp_cs cs
            | Some x -> (off + i + 1, x)
          else component Int64.(acc lsl 7) off (succ i) in

    try
      let b1 = get_uint8 cs 0 in
      let v1 = b1 / 40 and v2 = b1 mod 40 in
      base v1 v2 <|| values 1
    with Invalid_argument _ -> parse_error "OID: input: %a" pp_cs cs

  let to_writer = fun (Oid (v1, v2, vs)) ->
    let cons x = function [] -> [x] | xs -> x lor 0x80 :: xs in
    let rec component xs x =
      if x < 0x80 then cons x xs
      else component (cons (x land 0x7f) xs) (x lsr 7)
    and values = function
      | []    -> Writer.empty
      | v::vs -> Writer.(of_list (component [] v) <+> values vs) in
    Writer.(of_byte (v1 * 40 + v2) <+> values vs)

  let random () =
    Random.( base (int 3) (int 40) <|| replicate_l (int 10) random_int )
end

module Time = struct

  type t = Asn_time.t

  open Asn_time

  let catch pname f s = try f s with
  | End_of_file            -> parse_error "%s: input too short at %s" pname s
  | Scanf.Scan_failure err -> parse_error "%s: %s as %s" pname err s

  let frac f = f -. floor f

  let round f =
    int_of_float @@ if frac f < 0.5 then floor f else ceil f

  let tz_of_string_exn = function
    | "Z"|"" -> None
    | str    ->
        Scanf.sscanf str "%1[+-]%02u%02u%!" @@
          fun sgn h m -> match sgn with
            | "+" -> Some (h, m, `E)
            | "-" -> Some (h, m, `W)
            | _   -> None

  let time_of_string_utc = catch "UTCTime" @@ fun s ->
    Scanf.sscanf s "%02u%02u%02u%02u%02u%s" @@
    fun y m d hh mm rest ->
      let (ss, tz) =
        try Scanf.sscanf rest "%02u%s" @@ fun ss rest ->
          (ss, tz_of_string_exn rest)
        with _ -> (0, tz_of_string_exn rest) in
      let y = if y < 50 then 2000 + y else 1900 + y in
      { date = (y, m, d) ; time = (hh, mm, ss, 0.) ; tz }

  let time_of_string_gen = catch "GeneralizedTime" @@ fun s ->
    Scanf.sscanf s "%04u%02u%02u%02u%02u%s" @@
    fun y m d hh mm rest ->
      let (ssff, tz) =
        try Scanf.sscanf rest "%f%s" @@ fun ssff rest ->
          (ssff, tz_of_string_exn rest)
        with _ -> (0., tz_of_string_exn rest) in
      let ss = int_of_float ssff
      and ff = frac ssff in
      { date = (y, m, d) ; time = (hh, mm, ss, ff) ; tz }


  let tz_to_string = function
    | None             -> "Z"
    | Some (h, m, sgn) ->
        Printf.sprintf "%c%02d%02d"
          (match sgn with `E -> '+' | `W -> '-') h m

  let time_to_string_utc t =
    let (y, m, d)       = t.date
    and (hh, mm, ss, _) = t.time in
    Printf.sprintf "%02d%02d%02d%02d%02d%02d%s"
      (y mod 100) m d hh mm ss (tz_to_string t.tz)

  (* The most ridiculously convoluted way to print three decimal digits.
   * When in doubt, multiply 0.57 by 100. *)
  (* XXX Assumes x = a * 10^(-n) + epsilon for natural a, n. *)
  let string_of_frac n x =
    let i   = round (frac x *. 10. ** float n) in
    let str = string_of_int i in
    let rec rstrip_0 = function
      | 0 -> ""
      | i ->
          match str.[i - 1] with
          | '0' -> rstrip_0 (pred i)
          | _   -> "." ^ String.sub str 0 i in
    rstrip_0 String.(length str)

  (* XXX BER-times must be UTC-normalized. Not sure whether optional ss and ff
   * are allowed to be zero-only.  *)
  let time_to_string_gen t =
    let (y, m, d)        = t.date
    and (hh, mm, ss, ff) = t.time in
    Printf.sprintf "%04d%02d%02d%02d%02d%02d%s%s"
      y m d hh mm ss (string_of_frac 3 ff) (tz_to_string t.tz)


  let random ?(fraction=false) () =
    let num n = Random.int n + 1 in
    let sec   = if Random.int 3 = 0 then 0 else num 59
    and sec_f = if fraction then float (Random.int 1000) /. 1000. else 0.
    and tz    = match Random.int 3 with
      | 0 -> None
      | 1 -> Some (num 11, num 59, `E)
      | 2 -> Some (num 11, num 59, `W)
      | _ -> assert false
    in
    { date = (1950 + num 99, num 12, num 30) ;
      time = (num 23, num 59, sec, sec_f) ;
      tz   = tz }
end