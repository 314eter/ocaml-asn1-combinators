open Core

let arr_fold_right_i ~f z arr =
  let rec loop r = function
    | -1 -> r
    |  i -> loop (f i arr.(i) r) (pred i) in
  loop z Array.(length arr - 1)

let rec filter_map f = function
  | []    -> []
  | x::xs ->
      match f x with
      | None    ->       filter_map f xs
      | Some x' -> x' :: filter_map f xs

(* Horrible, horrible hack.
 * Extend the Core.asn type to fix. *)
module Fix_cache (T : sig type 'a t end) : sig
  val cached : ('a asn -> 'a asn) -> (unit -> 'a T.t) -> 'a T.t
  val add : ('a asn -> 'a asn) -> 'a T.t -> 'a T.t
  val find : ('a asn -> 'a asn) -> 'a T.t
end
=
struct
  let cast = Obj.magic
  let cache : (unit, unit) Hashtbl.t = Hashtbl.create 100
  let cached key cons =
    let key' = cast key in
    try cast (Hashtbl.find cache key') with
    | Not_found ->
        let res = cons () in
        ( Hashtbl.add cache key' (cast res) ; res )
  let add k v = ( Hashtbl.add cache (cast k) (cast v) ; v )
  let find k  = cast (Hashtbl.find cache @@ cast k)
end


type tag_class = [ `Universal | `Application | `Private ]

let fix f = Fix f

let map f g asn = Iso (f, g, asn)

let implicit, explicit =
  let tag = function
    | (None,              n) -> Context_specific n
    | (Some `Application, n) -> Application      n
    | (Some `Private,     n) -> Private          n
    | (Some `Universal,   n) -> Universal        n in
  (fun ?cls id asn -> Implicit (tag (cls, id), asn)) ,
  (fun ?cls id asn -> Explicit (tag (cls, id), asn))

let bool                = Prim Bool
and integer             = Prim Int
and octet_string        = Prim Octets
and null                = Prim Null
and oid                 = Prim OID
and utc_time            = Prim UTCTime
and generalized_time    = Prim GeneralizedTime

let utf8_string         = Prim UTF8String
and numeric_string      = Prim NumericString
and printable_string    = Prim PrintableString
and teletex_string      = Prim TeletexString
and videotex_string     = Prim VideotexString
and ia5_string          = Prim IA5String
and graphic_string      = Prim GraphicString
and visible_string      = Prim VisibleString
and general_string      = Prim GeneralString
and universal_string    = Prim UniversalString
and bmp_string          = Prim BMPString

let int =
  let f n =
    try Num.int_of_num n with Failure _ ->
      raise (Parse_error ("int: too large: " ^ Num.string_of_num n))
  in
  map f Num.num_of_int integer


let bit_string' =
  map snd (fun cs -> (0, cs)) (Prim Bits)
and bit_string  =
  Prim.Bits.(map array_of_pair pair_of_array (Prim Bits))

(* XXX
 * Encode clips array to highest set index. Maybe encode full range? *)
let flags (type a) (xs : (int * a) list) =
  let module M1 = Map.Make (struct type t = int let compare = compare end) in
  let module M2 = Map.Make (struct type t = a   let compare = compare end) in
  let m1 = List.fold_right (fun (i, x) -> M1.add i x) xs M1.empty
  and m2 = List.fold_right (fun (i, x) -> M2.add x i) xs M2.empty in
  let f =
    arr_fold_right_i [] ~f:(fun i b xs ->
      if b then (try M1.find i m1 :: xs with Not_found -> xs) else xs)
  and g list =
    let (ixs, n) =
      let rec loop ixs n = function
        | []    -> (ixs, n)
        | x::xs ->
            try
              let ix = M2.find x m2 in
              loop (ix :: ixs) (max n ix) xs
            with Not_found -> loop ixs n xs in
      loop [] (-1) list in
    let arr = Array.create (n + 1) false in
    List.iter (fun ix -> arr.(ix) <- true) ixs;
    arr
  in
  map f g bit_string

let big_natural =
  let open Prim.Integer in
  map nat_string_of_cs cs_of_nat_string @@
      implicit ~cls:`Universal 0x02 octet_string

let single a   = Last a
and ( @) a b   = Pair (a, b)
and (-@) a b   = Pair (a, Last b)
and optional ?label a = Optional (label, a)
and required ?label a = Required (label, a)

let product2 fn a b = fn @@ a @ single b

let product3 fn a b c =
  map (fun (a, (b, c)) -> (a, b, c))
      (fun (a, b, c) -> (a, (b, c)))
      (fn @@ a @ b @ single c)

let product4 fn a b c d =
  map (fun (a, (b, (c, d))) -> (a, b, c, d))
      (fun (a, b, c, d) -> (a, (b, (c, d))))
      (fn @@ a @ b @ c @ single d)

let product5 fn a b c d e =
  map (fun (a, (b, (c, (d, e)))) -> (a, b, c, d, e))
      (fun (a, b, c, d, e) -> (a, (b, (c, (d, e)))))
      (fn @@ a @ b @ c @ d @ single e)

let product6 fn a b c d e f =
  map (fun (a, (b, (c, (d, (e, f))))) -> (a, b, c, d, e, f))
      (fun (a, b, c, d, e, f) -> (a, (b, (c, (d, (e, f))))))
      (fn @@ a @ b @ c @ d @ e @ single f)


let sequence seq = Sequence seq

let sequence2 a b         = product2 sequence a b
and sequence3 a b c       = product3 sequence a b c
and sequence4 a b c d     = product4 sequence a b c d
and sequence5 a b c d e   = product5 sequence a b c d e
and sequence6 a b c d e f = product6 sequence a b c d e f

let sequence_of asn = Sequence_of asn

let set seq = Set seq

let set2 a b         = product2 set a b
and set3 a b c       = product3 set a b c
and set4 a b c d     = product4 set a b c d
and set5 a b c d e   = product5 set a b c d e
and set6 a b c d e f = product6 set a b c d e f

let set_of asn = Set_of asn

let choice a b = Choice (a, b)

let choice2 a b =
  map (function L a -> `C1 a | R b -> `C2 b)
      (function `C1 a -> L a | `C2 b -> R b)
      (choice a b)

let choice3 a b c =
  map (function L (L a) -> `C1 a | L (R b) -> `C2 b | R c -> `C3 c)
      (function `C1 a -> L (L a) | `C2 b -> L (R b) | `C3 c -> R c)
      (choice (choice a b) c)

let choice4 a b c d =
  map (function | L (L a) -> `C1 a | L (R b) -> `C2 b
                | R (L c) -> `C3 c | R (R d) -> `C4 d)
      (function | `C1 a -> L (L a) | `C2 b -> L (R b)
                | `C3 c -> R (L c) | `C4 d -> R (R d))
      (choice (choice a b) (choice c d))

let choice5 a b c d e =
  map (function | L (L (L a)) -> `C1 a | L (L (R b)) -> `C2 b
                | L (R c) -> `C3 c
                | R (L d) -> `C4 d | R (R e) -> `C5 e)
      (function | `C1 a -> L (L (L a)) | `C2 b -> L (L (R b))
                | `C3 c -> L (R c)
                | `C4 d -> R (L d) | `C5 e -> R (R e))
      (choice (choice (choice a b) c) (choice d e))

let choice6 a b c d e f =
  map (function | L (L (L a)) -> `C1 a | L (L (R b)) -> `C2 b
                | L (R c) -> `C3 c
                | R (L (L d)) -> `C4 d | R (L (R e)) -> `C5 e
                | R (R f) -> `C6 f)
      (function | `C1 a -> L (L (L a)) | `C2 b -> L (L (R b))
                | `C3 c -> L (R c)
                | `C4 d -> R (L (L d)) | `C5 e -> R (L (R e))
                | `C6 f -> R (R f))
      (choice (choice (choice a b) c) (choice (choice d e) f))


(*
 * Check tag ambiguity.
 * XXX Maybe add no-implicit-over-choice check.
 *)

let validate asn =

  let module C  = Fix_cache (struct type 'a t = unit end) in

  let rec disjunct tss =
    let rec go = function
      | t::(u::_ as ts) ->
          if t <> u then go ts else (
            (* XXX USE LABELS TO REPORT *)
            Printf.printf "bad at: %s\n%!" @@
              String.concat "  " @@ List.map string_of_tags tss ;
            raise Ambiguous_grammar
          )
      | [] | [_] -> () in
    go List.(sort compare @@ concat tss)

  and ck_seq : type a. tags list * a sequence -> unit = function

    | ts, Last (Optional (_label, x)) ->
        ( check x ; disjunct (tag_set x :: ts) )
    | [], Last (Required (_label, x)) ->
        ( check x )
    | ts, Last (Required (_label, x)) ->
        ( check x ; disjunct (tag_set x :: ts) )
    | ts, Pair (Optional (_label, x), xs) ->
        ( check x ; ck_seq (tag_set x :: ts, xs) )
    | [], Pair (Required (_label, x), xs) ->
        ( check x ; ck_seq ([], xs) )
    | ts, Pair (Required (_label, x), xs) ->
        ( check x ; disjunct (tag_set x :: ts) ; ck_seq ([], xs) )

  and ck_set : type a. a sequence -> tags list = function

    | Last (Required (_, x))     -> check x ; [ tag_set x ]
    | Last (Optional (_, x))     -> check x ; [ tag_set x ]
    | Pair (Required (_, x), xs) -> check x ; tag_set x :: ck_set xs
    | Pair (Optional (_, x), xs) -> check x ; tag_set x :: ck_set xs

  and check : type a. a asn -> unit = function

    | Iso (_, _, asn) -> check asn
    | Fix f as fix ->
      ( try C.find f with Not_found -> C.add f () ; check (f fix) )

    | Sequence asns   -> ck_seq ([], asns)
    | Set      asns   -> disjunct @@ ck_set asns
    | Sequence_of asn -> check asn
    | Set_of      asn -> check asn

    | Choice (asn1, asn2) ->
        disjunct [ tag_set asn1; tag_set asn2 ] ; check asn1 ; check asn2

    | Implicit (_, asn) -> check asn
    | Explicit (_, asn) -> check asn
    | Prim _ -> () in

  try check asn with Stack_overflow -> raise Ambiguous_grammar


