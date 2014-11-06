
type t = private Oid of int * int * int list

val (<|)      : t -> int -> t
val (<||)     : t -> int list -> t
val base      : int -> int -> t

val to_list   : t -> int list
val to_string : t -> string
val of_string : string -> t

val compare : t -> t -> int
val equal : t -> t -> bool
val hash : t -> int
