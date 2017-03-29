module Spec.Ed25519

open FStar.Mul
open FStar.Seq
open FStar.Endianness
open FStar.UInt8
open Spec.Lib
open Spec.SHA2.Core
open Spec.Curve25519


#reset-options "--max_fuel 0 --max_ifuel 0 --z3rlimit 20"

(* Point addition *)
type aff_point = tuple2 elem elem           // Affine point
type ext_point = tuple4 elem elem elem elem // Homogeneous extended coordinates

let sha512 (b:bytes{length b < pow2 125}) : Tot (lbytes 64) = 
  hash' b

let modp_inv (x:elem) : Tot elem =
  x ** (prime - 2)

let d : elem =
  ( - 121665 * modp_inv 121666 ) % prime

let q: elem = 
  assert_norm(pow2 252 + 27742317777372353535851937790883648493 < pow2 255 - 19);
  pow2 252 + 27742317777372353535851937790883648493 // Group order

let sha512_modq (s:bytes{length s < pow2 125}) : Tot elem =
  little_endian (sha512 s) % q

let point_add (p:ext_point) (q:ext_point) : Tot ext_point =
  let x1, y1, z1, t1 = p in
  let x2, y2, z2, t2 = q in
  let a = (y1 `fsub` x1) `fmul` (y2 `fsub` x2) in
  let b = (y1 `fadd` x1) `fmul` (y2 `fadd` x2) in
  let c = t1 `fmul` 2 `fmul` d `fmul` t2 in
  let d = z1 `fmul` 2 `fmul` z2 in
  let e = b `fsub` a in
  let f = d `fsub` c in
  let g = d `fadd` c in
  let h = b `fadd` a in
  let x3 = e `fmul` f in
  let y3 = g `fmul` h in
  let t3 = e `fmul` h in
  let z3 = f `fmul` g in
  (x3, y3, z3, t3)

let point_double (p:ext_point) : Tot ext_point =
  let x1, y1, z1, t1 = p in
  let a = x1 ** 2 in
  let b = y1 ** 2 in
  let c = 2 `fmul` (z1 ** 2) in
  let h = a `fadd` b in
  let e = h `fsub` ((x1 `fadd` y1) ** 2) in
  let g = a `fsub` b in
  let f = c `fadd` g in
  let x3 = e `fmul` f in
  let y3 = g `fmul` h in
  let t3 = e `fmul` h in
  let z3 = f `fmul` g in
  (x3, y3, z3, t3)

#reset-options "--max_fuel 0 --max_ifuel 0 --z3rlimit 100"

let ith_bit (k:bytes) (i:nat{i < 8 * length k}) =
  let q = i / 8 in let r = i % 8 in
  (v (k.[q]) / pow2 r) % 2

let rec montgomery_ladder_ (x:ext_point) (xp1:ext_point) (k:bytes) (ctr:nat{ ctr <= 8 * length k})
  : Tot ext_point (decreases ctr) =
  if ctr = 0 then x
  else (
    let ctr' = ctr - 1 in
    let (x', xp1') =
      if ith_bit k ctr' = 1 then (
        let nqp2 = point_double xp1 in
        let nqp1 = point_add x xp1 in
        nqp1, nqp2
      ) else (
        let nqp1 = point_double x in
        let nqp2 = point_add x xp1 in
        nqp1, nqp2
      ) in
    montgomery_ladder_ x' xp1' k ctr'
  )

let point_mul (a:bytes) (p:ext_point) =
  montgomery_ladder_ (zero, one, one, zero) p a (8 * length a)

let modp_sqrt_m1 : elem = 2 ** ((prime - 1) / 4)

noeq type record = { s:(s':seq bool{length s' = 3})}

let recover_x (y:elem) (sign:bool) : Tot (option elem) =
  if y >= prime then None
  else (
    let x2 = ((y `fmul` y) `fsub` 1) `fmul` (modp_inv ((d `fmul` y `fmul` y) `fadd` one)) in
    if x2 = zero then (
      if sign then None
      else Some zero
    ) else (
      let x = x2 ** ((prime + 3) / 8) in
      let x = if ((x `fmul` x) `fsub` x2) <> zero then x `fmul` modp_sqrt_m1 else x in
      if ((x `fmul` x) `fsub` x2) <> zero then None
      else (
        let x = if (x % 2 = 1) <> sign then prime `fsub` x else x in
        Some x)))
        
let g_y : elem = 4 `fmul` (modp_inv 5)
let g_x : elem = 
  assume (Some? (recover_x g_y false));
  Some?.v (recover_x g_y false)

let g: ext_point = (g_x, g_y, 1, g_x `fmul` g_y)

let point_compress (p:ext_point) : Tot (lbytes 32) =
  let px, py, pz, pt = p in
  let zinv = modp_inv pz in
  let x = px `fmul` zinv in
  let y = py `fmul` zinv in
  little_bytes 32ul ((pow2 255 * (x % 2)) + y)

let point_decompress (s:lbytes 32) : Tot (option ext_point) =
  let y = little_endian s in
  let sign = (y / pow2 255) % 2 = 1 in
  let y = y % (pow2 255) in
  let x = recover_x y sign in
  match x with
  | Some x -> Some (x, y, one, x `fmul` y)
  | _ -> None

let secret_expand (secret:lbytes 32) =
  let h = sha512 secret in
  let h_low, h_high = split h 32 in
  let h_low0  = h_low.[0] in
  let h_low31 = h_low.[31] in
  let h_low = h_low.[ 0] <- (h_low0 &^ 0xf8uy) in
  let h_low = h_low.[31] <- ((h_low31 &^ 127uy) |^ 64uy) in
  h_low, h_high

let secret_to_public (secret:lbytes 32) =
  let a, dummy = secret_expand secret in
  point_compress (point_mul a g)

let sign (secret:lbytes 32) (msg:bytes) =
  let a, prefix = secret_expand secret in
  let a' = point_compress (point_mul a g) in
  let r = sha512_modq (prefix @| msg) in
  let r' = point_mul (little_bytes 32ul r) g in
  let rs = point_compress r' in
  let h = sha512_modq (rs @| a' @| msg) in
  (* let s = (r `fadd` (h `fmul` (little_endian a))) % q in *)
  let s = (r + (h * (little_endian a))) % q in
  rs @| little_bytes 32ul s

let point_equal p q =
  let px, py, pz, pt = p in
  let qx, qy, qz, qt = q in
  if ((px `fmul` qz) `fsub` (qx `fmul` pz)) <> zero then false
  else if ((py `fmul` qz) `fsub` (qy `fmul` pz)) <> zero then false
  else true

let verify (public:lbytes 32) (msg:bytes) (signature:lbytes 64) =
  let a' = point_decompress public in
  match a' with
  | None -> false
  | Some a' -> (
      let rs = slice signature 0 32 in
      let r' = point_decompress rs in
      match r' with
      | None -> false
      | Some r' -> (
          let s = little_endian (slice signature 32 64) in
          if s >= q then false
          else (
            let h = sha512_modq (rs @| public @| msg) in
            let sB = point_mul (little_bytes 32ul s) g in
            let hA = point_mul (little_bytes 32ul h) a' in
            point_equal sB (point_add r' hA)
          )))


#set-options "--lax"

let sk1 = [0x9duy; 0x61uy; 0xb1uy; 0x9duy; 0xefuy; 0xfduy; 0x5auy; 0x60uy;
           0xbauy; 0x84uy; 0x4auy; 0xf4uy; 0x92uy; 0xecuy; 0x2cuy; 0xc4uy;
           0x44uy; 0x49uy; 0xc5uy; 0x69uy; 0x7buy; 0x32uy; 0x69uy; 0x19uy;
           0x70uy; 0x3buy; 0xacuy; 0x03uy; 0x1cuy; 0xaeuy; 0x7fuy; 0x60uy]

let pk1 = [0xd7uy; 0x5auy; 0x98uy; 0x01uy; 0x82uy; 0xb1uy; 0x0auy; 0xb7uy; 
           0xd5uy; 0x4buy; 0xfeuy; 0xd3uy; 0xc9uy; 0x64uy; 0x07uy; 0x3auy;
           0x0euy; 0xe1uy; 0x72uy; 0xf3uy; 0xdauy; 0xa6uy; 0x23uy; 0x25uy;
           0xafuy; 0x02uy; 0x1auy; 0x68uy; 0xf7uy; 0x07uy; 0x51uy; 0x1auy]

let msg1: list byte = []

let sig1 = [0xe5uy; 0x56uy; 0x43uy; 0x00uy; 0xc3uy; 0x60uy; 0xacuy; 0x72uy;
            0x90uy; 0x86uy; 0xe2uy; 0xccuy; 0x80uy; 0x6euy; 0x82uy; 0x8auy; 
            0x84uy; 0x87uy; 0x7fuy; 0x1euy; 0xb8uy; 0xe5uy; 0xd9uy; 0x74uy;
            0xd8uy; 0x73uy; 0xe0uy; 0x65uy; 0x22uy; 0x49uy; 0x01uy; 0x55uy;
            0x5fuy; 0xb8uy; 0x82uy; 0x15uy; 0x90uy; 0xa3uy; 0x3buy; 0xacuy; 
            0xc6uy; 0x1euy; 0x39uy; 0x70uy; 0x1cuy; 0xf9uy; 0xb4uy; 0x6buy;
            0xd2uy; 0x5buy; 0xf5uy; 0xf0uy; 0x59uy; 0x5buy; 0xbeuy; 0x24uy; 
            0x65uy; 0x51uy; 0x41uy; 0x43uy; 0x8euy; 0x7auy; 0x10uy; 0x0buy]


let sk2 = [0x4cuy; 0xcduy; 0x08uy; 0x9buy; 0x28uy; 0xffuy; 0x96uy; 0xdauy; 0x9duy; 0xb6uy; 0xc3uy; 0x46uy; 0xecuy; 0x11uy; 0x4euy; 0x0fuy; 0x5buy; 0x8auy; 0x31uy; 0x9fuy; 0x35uy; 0xabuy; 0xa6uy; 0x24uy; 0xdauy; 0x8cuy; 0xf6uy; 0xeduy; 0x4fuy; 0xb8uy; 0xa6uy; 0xfbuy]

let pk2 = [0x3duy; 0x40uy; 0x17uy; 0xc3uy; 0xe8uy; 0x43uy; 0x89uy; 0x5auy; 0x92uy; 0xb7uy; 0x0auy; 0xa7uy; 0x4duy; 0x1buy; 0x7euy; 0xbcuy; 0x9cuy; 0x98uy; 0x2cuy; 0xcfuy; 0x2euy; 0xc4uy; 0x96uy; 0x8cuy; 0xc0uy; 0xcduy; 0x55uy; 0xf1uy; 0x2auy; 0xf4uy; 0x66uy; 0x0cuy]

let msg2 = [0x72uy]

let sig2 = [0x92uy; 0xa0uy; 0x09uy; 0xa9uy; 0xf0uy; 0xd4uy; 0xcauy; 0xb8uy;
            0x72uy; 0x0euy; 0x82uy; 0x0buy; 0x5fuy; 0x64uy; 0x25uy; 0x40uy;
            0xa2uy; 0xb2uy; 0x7buy; 0x54uy; 0x16uy; 0x50uy; 0x3fuy; 0x8fuy; 
            0xb3uy; 0x76uy; 0x22uy; 0x23uy; 0xebuy; 0xdbuy; 0x69uy; 0xdauy;
            0x08uy; 0x5auy; 0xc1uy; 0xe4uy; 0x3euy; 0x15uy; 0x99uy; 0x6euy; 
            0x45uy; 0x8fuy; 0x36uy; 0x13uy; 0xd0uy; 0xf1uy; 0x1duy; 0x8cuy;
            0x38uy; 0x7buy; 0x2euy; 0xaeuy; 0xb4uy; 0x30uy; 0x2auy; 0xeeuy;
            0xb0uy; 0x0duy; 0x29uy; 0x16uy; 0x12uy; 0xbbuy; 0x0cuy; 0x00uy]

let sk3 = [0xc5uy; 0xaauy; 0x8duy; 0xf4uy; 0x3fuy; 0x9fuy; 0x83uy; 0x7buy;
           0xeduy; 0xb7uy; 0x44uy; 0x2fuy; 0x31uy; 0xdcuy; 0xb7uy; 0xb1uy;
           0x66uy; 0xd3uy; 0x85uy; 0x35uy; 0x07uy; 0x6fuy; 0x09uy; 0x4buy;
           0x85uy; 0xceuy; 0x3auy; 0x2euy; 0x0buy; 0x44uy; 0x58uy; 0xf7uy]

let pk3 = [0xfcuy; 0x51uy; 0xcduy; 0x8euy; 0x62uy; 0x18uy; 0xa1uy; 0xa3uy;
           0x8duy; 0xa4uy; 0x7euy; 0xd0uy; 0x02uy; 0x30uy; 0xf0uy; 0x58uy;
           0x08uy; 0x16uy; 0xeduy; 0x13uy; 0xbauy; 0x33uy; 0x03uy; 0xacuy;
           0x5duy; 0xebuy; 0x91uy; 0x15uy; 0x48uy; 0x90uy; 0x80uy; 0x25uy]

let msg3 = [0xafuy; 0x82uy]

let sig3 = [0x62uy; 0x91uy; 0xd6uy; 0x57uy; 0xdeuy; 0xecuy; 0x24uy; 0x02uy; 
            0x48uy; 0x27uy; 0xe6uy; 0x9cuy; 0x3auy; 0xbeuy; 0x01uy; 0xa3uy;
            0x0cuy; 0xe5uy; 0x48uy; 0xa2uy; 0x84uy; 0x74uy; 0x3auy; 0x44uy;
            0x5euy; 0x36uy; 0x80uy; 0xd7uy; 0xdbuy; 0x5auy; 0xc3uy; 0xacuy;
            0x18uy; 0xffuy; 0x9buy; 0x53uy; 0x8duy; 0x16uy; 0xf2uy; 0x90uy;
            0xaeuy; 0x67uy; 0xf7uy; 0x60uy; 0x98uy; 0x4duy; 0xc6uy; 0x59uy;
            0x4auy; 0x7cuy; 0x15uy; 0xe9uy; 0x71uy; 0x6euy; 0xd2uy; 0x8duy;
            0xc0uy; 0x27uy; 0xbeuy; 0xceuy; 0xeauy; 0x1euy; 0xc4uy; 0x0auy]

let sk4 = [0xf5uy; 0xe5uy; 0x76uy; 0x7cuy; 0xf1uy; 0x53uy; 0x31uy; 0x95uy;
           0x17uy; 0x63uy; 0x0fuy; 0x22uy; 0x68uy; 0x76uy; 0xb8uy; 0x6cuy;
           0x81uy; 0x60uy; 0xccuy; 0x58uy; 0x3buy; 0xc0uy; 0x13uy; 0x74uy;
           0x4cuy; 0x6buy; 0xf2uy; 0x55uy; 0xf5uy; 0xccuy; 0x0euy; 0xe5uy]

let pk4 = [0x27uy; 0x81uy; 0x17uy; 0xfcuy; 0x14uy; 0x4cuy; 0x72uy; 0x34uy;
           0x0fuy; 0x67uy; 0xd0uy; 0xf2uy; 0x31uy; 0x6euy; 0x83uy; 0x86uy;
           0xceuy; 0xffuy; 0xbfuy; 0x2buy; 0x24uy; 0x28uy; 0xc9uy; 0xc5uy;
           0x1fuy; 0xefuy; 0x7cuy; 0x59uy; 0x7fuy; 0x1duy; 0x42uy; 0x6euy]

let msg4 = [0x08uy; 0xb8uy; 0xb2uy; 0xb7uy; 0x33uy; 0x42uy; 0x42uy; 0x43uy;
            0x76uy; 0x0fuy; 0xe4uy; 0x26uy; 0xa4uy; 0xb5uy; 0x49uy; 0x08uy;
            0x63uy; 0x21uy; 0x10uy; 0xa6uy; 0x6cuy; 0x2fuy; 0x65uy; 0x91uy;
            0xeauy; 0xbduy; 0x33uy; 0x45uy; 0xe3uy; 0xe4uy; 0xebuy; 0x98uy;
            0xfauy; 0x6euy; 0x26uy; 0x4buy; 0xf0uy; 0x9euy; 0xfeuy; 0x12uy;
            0xeeuy; 0x50uy; 0xf8uy; 0xf5uy; 0x4euy; 0x9fuy; 0x77uy; 0xb1uy;
            0xe3uy; 0x55uy; 0xf6uy; 0xc5uy; 0x05uy; 0x44uy; 0xe2uy; 0x3fuy;
            0xb1uy; 0x43uy; 0x3duy; 0xdfuy; 0x73uy; 0xbeuy; 0x84uy; 0xd8uy;
            0x79uy; 0xdeuy; 0x7cuy; 0x00uy; 0x46uy; 0xdcuy; 0x49uy; 0x96uy;
            0xd9uy; 0xe7uy; 0x73uy; 0xf4uy; 0xbcuy; 0x9euy; 0xfeuy; 0x57uy;
            0x38uy; 0x82uy; 0x9auy; 0xdbuy; 0x26uy; 0xc8uy; 0x1buy; 0x37uy;
            0xc9uy; 0x3auy; 0x1buy; 0x27uy; 0x0buy; 0x20uy; 0x32uy; 0x9duy;
            0x65uy; 0x86uy; 0x75uy; 0xfcuy; 0x6euy; 0xa5uy; 0x34uy; 0xe0uy;
            0x81uy; 0x0auy; 0x44uy; 0x32uy; 0x82uy; 0x6buy; 0xf5uy; 0x8cuy;
            0x94uy; 0x1euy; 0xfbuy; 0x65uy; 0xd5uy; 0x7auy; 0x33uy; 0x8buy;
            0xbduy; 0x2euy; 0x26uy; 0x64uy; 0x0fuy; 0x89uy; 0xffuy; 0xbcuy;
            0x1auy; 0x85uy; 0x8euy; 0xfcuy; 0xb8uy; 0x55uy; 0x0euy; 0xe3uy;
            0xa5uy; 0xe1uy; 0x99uy; 0x8buy; 0xd1uy; 0x77uy; 0xe9uy; 0x3auy;
            0x73uy; 0x63uy; 0xc3uy; 0x44uy; 0xfeuy; 0x6buy; 0x19uy; 0x9euy;            
            0xe5uy; 0xd0uy; 0x2euy; 0x82uy; 0xd5uy; 0x22uy; 0xc4uy; 0xfeuy;
            0xbauy; 0x15uy; 0x45uy; 0x2fuy; 0x80uy; 0x28uy; 0x8auy; 0x82uy;
            0x1auy; 0x57uy; 0x91uy; 0x16uy; 0xecuy; 0x6duy; 0xaduy; 0x2buy;
            0x3buy; 0x31uy; 0x0duy; 0xa9uy; 0x03uy; 0x40uy; 0x1auy; 0xa6uy;
            0x21uy; 0x00uy; 0xabuy; 0x5duy; 0x1auy; 0x36uy; 0x55uy; 0x3euy;
            0x06uy; 0x20uy; 0x3buy; 0x33uy; 0x89uy; 0x0cuy; 0xc9uy; 0xb8uy;
            0x32uy; 0xf7uy; 0x9euy; 0xf8uy; 0x05uy; 0x60uy; 0xccuy; 0xb9uy;
            0xa3uy; 0x9cuy; 0xe7uy; 0x67uy; 0x96uy; 0x7euy; 0xd6uy; 0x28uy;
            0xc6uy; 0xaduy; 0x57uy; 0x3cuy; 0xb1uy; 0x16uy; 0xdbuy; 0xefuy;
            0xefuy; 0xd7uy; 0x54uy; 0x99uy; 0xdauy; 0x96uy; 0xbduy; 0x68uy;
            0xa8uy; 0xa9uy; 0x7buy; 0x92uy; 0x8auy; 0x8buy; 0xbcuy; 0x10uy;
            0x3buy; 0x66uy; 0x21uy; 0xfcuy; 0xdeuy; 0x2buy; 0xecuy; 0xa1uy;
            0x23uy; 0x1duy; 0x20uy; 0x6buy; 0xe6uy; 0xcduy; 0x9euy; 0xc7uy;
            0xafuy; 0xf6uy; 0xf6uy; 0xc9uy; 0x4fuy; 0xcduy; 0x72uy; 0x04uy;
            0xeduy; 0x34uy; 0x55uy; 0xc6uy; 0x8cuy; 0x83uy; 0xf4uy; 0xa4uy;
            0x1duy; 0xa4uy; 0xafuy; 0x2buy; 0x74uy; 0xefuy; 0x5cuy; 0x53uy;
            0xf1uy; 0xd8uy; 0xacuy; 0x70uy; 0xbduy; 0xcbuy; 0x7euy; 0xd1uy;
            0x85uy; 0xceuy; 0x81uy; 0xbduy; 0x84uy; 0x35uy; 0x9duy; 0x44uy;
            0x25uy; 0x4duy; 0x95uy; 0x62uy; 0x9euy; 0x98uy; 0x55uy; 0xa9uy;
            0x4auy; 0x7cuy; 0x19uy; 0x58uy; 0xd1uy; 0xf8uy; 0xaduy; 0xa5uy;
            0xd0uy; 0x53uy; 0x2euy; 0xd8uy; 0xa5uy; 0xaauy; 0x3fuy; 0xb2uy;
            0xd1uy; 0x7buy; 0xa7uy; 0x0euy; 0xb6uy; 0x24uy; 0x8euy; 0x59uy;
            0x4euy; 0x1auy; 0x22uy; 0x97uy; 0xacuy; 0xbbuy; 0xb3uy; 0x9duy;
            0x50uy; 0x2fuy; 0x1auy; 0x8cuy; 0x6euy; 0xb6uy; 0xf1uy; 0xceuy;
            0x22uy; 0xb3uy; 0xdeuy; 0x1auy; 0x1fuy; 0x40uy; 0xccuy; 0x24uy;
            0x55uy; 0x41uy; 0x19uy; 0xa8uy; 0x31uy; 0xa9uy; 0xaauy; 0xd6uy;
            0x07uy; 0x9cuy; 0xaduy; 0x88uy; 0x42uy; 0x5duy; 0xe6uy; 0xbduy;
            0xe1uy; 0xa9uy; 0x18uy; 0x7euy; 0xbbuy; 0x60uy; 0x92uy; 0xcfuy;
            0x67uy; 0xbfuy; 0x2buy; 0x13uy; 0xfduy; 0x65uy; 0xf2uy; 0x70uy; 
            0x88uy; 0xd7uy; 0x8buy; 0x7euy; 0x88uy; 0x3cuy; 0x87uy; 0x59uy;
            0xd2uy; 0xc4uy; 0xf5uy; 0xc6uy; 0x5auy; 0xdbuy; 0x75uy; 0x53uy;
            0x87uy; 0x8auy; 0xd5uy; 0x75uy; 0xf9uy; 0xfauy; 0xd8uy; 0x78uy;
            0xe8uy; 0x0auy; 0x0cuy; 0x9buy; 0xa6uy; 0x3buy; 0xcbuy; 0xccuy;
            0x27uy; 0x32uy; 0xe6uy; 0x94uy; 0x85uy; 0xbbuy; 0xc9uy; 0xc9uy;
            0x0buy; 0xfbuy; 0xd6uy; 0x24uy; 0x81uy; 0xd9uy; 0x08uy; 0x9buy;
            0xecuy; 0xcfuy; 0x80uy; 0xcfuy; 0xe2uy; 0xdfuy; 0x16uy; 0xa2uy;
            0xcfuy; 0x65uy; 0xbduy; 0x92uy; 0xdduy; 0x59uy; 0x7buy; 0x07uy;
            0x07uy; 0xe0uy; 0x91uy; 0x7auy; 0xf4uy; 0x8buy; 0xbbuy; 0x75uy; 
            0xfeuy; 0xd4uy; 0x13uy; 0xd2uy; 0x38uy; 0xf5uy; 0x55uy; 0x5auy;
            0x7auy; 0x56uy; 0x9duy; 0x80uy; 0xc3uy; 0x41uy; 0x4auy; 0x8duy;
            0x08uy; 0x59uy; 0xdcuy; 0x65uy; 0xa4uy; 0x61uy; 0x28uy; 0xbauy;
            0xb2uy; 0x7auy; 0xf8uy; 0x7auy; 0x71uy; 0x31uy; 0x4fuy; 0x31uy; 
            0x8cuy; 0x78uy; 0x2buy; 0x23uy; 0xebuy; 0xfeuy; 0x80uy; 0x8buy; 
            0x82uy; 0xb0uy; 0xceuy; 0x26uy; 0x40uy; 0x1duy; 0x2euy; 0x22uy;
            0xf0uy; 0x4duy; 0x83uy; 0xd1uy; 0x25uy; 0x5duy; 0xc5uy; 0x1auy;
            0xdduy; 0xd3uy; 0xb7uy; 0x5auy; 0x2buy; 0x1auy; 0xe0uy; 0x78uy; 
            0x45uy; 0x04uy; 0xdfuy; 0x54uy; 0x3auy; 0xf8uy; 0x96uy; 0x9buy; 
            0xe3uy; 0xeauy; 0x70uy; 0x82uy; 0xffuy; 0x7fuy; 0xc9uy; 0x88uy;
            0x8cuy; 0x14uy; 0x4duy; 0xa2uy; 0xafuy; 0x58uy; 0x42uy; 0x9euy; 
            0xc9uy; 0x60uy; 0x31uy; 0xdbuy; 0xcauy; 0xd3uy; 0xdauy; 0xd9uy; 
            0xafuy; 0x0duy; 0xcbuy; 0xaauy; 0xafuy; 0x26uy; 0x8cuy; 0xb8uy; 
            0xfcuy; 0xffuy; 0xeauy; 0xd9uy; 0x4fuy; 0x3cuy; 0x7cuy; 0xa4uy;
            0x95uy; 0xe0uy; 0x56uy; 0xa9uy; 0xb4uy; 0x7auy; 0xcduy; 0xb7uy; 
            0x51uy; 0xfbuy; 0x73uy; 0xe6uy; 0x66uy; 0xc6uy; 0xc6uy; 0x55uy; 
            0xaduy; 0xe8uy; 0x29uy; 0x72uy; 0x97uy; 0xd0uy; 0x7auy; 0xd1uy; 
            0xbauy; 0x5euy; 0x43uy; 0xf1uy; 0xbcuy; 0xa3uy; 0x23uy; 0x01uy; 
            0x65uy; 0x13uy; 0x39uy; 0xe2uy; 0x29uy; 0x04uy; 0xccuy; 0x8cuy; 
            0x42uy; 0xf5uy; 0x8cuy; 0x30uy; 0xc0uy; 0x4auy; 0xafuy; 0xdbuy;
            0x03uy; 0x8duy; 0xdauy; 0x08uy; 0x47uy; 0xdduy; 0x98uy; 0x8duy;
            0xcduy; 0xa6uy; 0xf3uy; 0xbfuy; 0xd1uy; 0x5cuy; 0x4buy; 0x4cuy;
            0x45uy; 0x25uy; 0x00uy; 0x4auy; 0xa0uy; 0x6euy; 0xefuy; 0xf8uy;
            0xcauy; 0x61uy; 0x78uy; 0x3auy; 0xacuy; 0xecuy; 0x57uy; 0xfbuy;
            0x3duy; 0x1fuy; 0x92uy; 0xb0uy; 0xfeuy; 0x2fuy; 0xd1uy; 0xa8uy;
            0x5fuy; 0x67uy; 0x24uy; 0x51uy; 0x7buy; 0x65uy; 0xe6uy; 0x14uy;
            0xaduy; 0x68uy; 0x08uy; 0xd6uy; 0xf6uy; 0xeeuy; 0x34uy; 0xdfuy;
            0xf7uy; 0x31uy; 0x0fuy; 0xdcuy; 0x82uy; 0xaeuy; 0xbfuy; 0xd9uy;
            0x04uy; 0xb0uy; 0x1euy; 0x1duy; 0xc5uy; 0x4buy; 0x29uy; 0x27uy;
            0x09uy; 0x4buy; 0x2duy; 0xb6uy; 0x8duy; 0x6fuy; 0x90uy; 0x3buy;
            0x68uy; 0x40uy; 0x1auy; 0xdeuy; 0xbfuy; 0x5auy; 0x7euy; 0x08uy;
            0xd7uy; 0x8fuy; 0xf4uy; 0xefuy; 0x5duy; 0x63uy; 0x65uy; 0x3auy;
            0x65uy; 0x04uy; 0x0cuy; 0xf9uy; 0xbfuy; 0xd4uy; 0xacuy; 0xa7uy;
            0x98uy; 0x4auy; 0x74uy; 0xd3uy; 0x71uy; 0x45uy; 0x98uy; 0x67uy;
            0x80uy; 0xfcuy; 0x0buy; 0x16uy; 0xacuy; 0x45uy; 0x16uy; 0x49uy;
            0xdeuy; 0x61uy; 0x88uy; 0xa7uy; 0xdbuy; 0xdfuy; 0x19uy; 0x1fuy;
            0x64uy; 0xb5uy; 0xfcuy; 0x5euy; 0x2auy; 0xb4uy; 0x7buy; 0x57uy;
            0xf7uy; 0xf7uy; 0x27uy; 0x6cuy; 0xd4uy; 0x19uy; 0xc1uy; 0x7auy;
            0x3cuy; 0xa8uy; 0xe1uy; 0xb9uy; 0x39uy; 0xaeuy; 0x49uy; 0xe4uy;
            0x88uy; 0xacuy; 0xbauy; 0x6buy; 0x96uy; 0x56uy; 0x10uy; 0xb5uy;
            0x48uy; 0x01uy; 0x09uy; 0xc8uy; 0xb1uy; 0x7buy; 0x80uy; 0xe1uy;
            0xb7uy; 0xb7uy; 0x50uy; 0xdfuy; 0xc7uy; 0x59uy; 0x8duy; 0x5duy;
            0x50uy; 0x11uy; 0xfduy; 0x2duy; 0xccuy; 0x56uy; 0x00uy; 0xa3uy;
            0x2euy; 0xf5uy; 0xb5uy; 0x2auy; 0x1euy; 0xccuy; 0x82uy; 0x0euy;
            0x30uy; 0x8auy; 0xa3uy; 0x42uy; 0x72uy; 0x1auy; 0xacuy; 0x09uy;
            0x43uy; 0xbfuy; 0x66uy; 0x86uy; 0xb6uy; 0x4buy; 0x25uy; 0x79uy;
            0x37uy; 0x65uy; 0x04uy; 0xccuy; 0xc4uy; 0x93uy; 0xd9uy; 0x7euy;
            0x6auy; 0xeduy; 0x3fuy; 0xb0uy; 0xf9uy; 0xcduy; 0x71uy; 0xa4uy;
            0x3duy; 0xd4uy; 0x97uy; 0xf0uy; 0x1fuy; 0x17uy; 0xc0uy; 0xe2uy;
            0xcbuy; 0x37uy; 0x97uy; 0xaauy; 0x2auy; 0x2fuy; 0x25uy; 0x66uy;
            0x56uy; 0x16uy; 0x8euy; 0x6cuy; 0x49uy; 0x6auy; 0xfcuy; 0x5fuy;
            0xb9uy; 0x32uy; 0x46uy; 0xf6uy; 0xb1uy; 0x11uy; 0x63uy; 0x98uy;
            0xa3uy; 0x46uy; 0xf1uy; 0xa6uy; 0x41uy; 0xf3uy; 0xb0uy; 0x41uy;
            0xe9uy; 0x89uy; 0xf7uy; 0x91uy; 0x4fuy; 0x90uy; 0xccuy; 0x2cuy;
            0x7fuy; 0xffuy; 0x35uy; 0x78uy; 0x76uy; 0xe5uy; 0x06uy; 0xb5uy;
            0x0duy; 0x33uy; 0x4buy; 0xa7uy; 0x7cuy; 0x22uy; 0x5buy; 0xc3uy;
            0x07uy; 0xbauy; 0x53uy; 0x71uy; 0x52uy; 0xf3uy; 0xf1uy; 0x61uy;
            0x0euy; 0x4euy; 0xafuy; 0xe5uy; 0x95uy; 0xf6uy; 0xd9uy; 0xd9uy;
            0x0duy; 0x11uy; 0xfauy; 0xa9uy; 0x33uy; 0xa1uy; 0x5euy; 0xf1uy;
            0x36uy; 0x95uy; 0x46uy; 0x86uy; 0x8auy; 0x7fuy; 0x3auy; 0x45uy;
            0xa9uy; 0x67uy; 0x68uy; 0xd4uy; 0x0fuy; 0xd9uy; 0xd0uy; 0x34uy;
            0x12uy; 0xc0uy; 0x91uy; 0xc6uy; 0x31uy; 0x5cuy; 0xf4uy; 0xfduy;
            0xe7uy; 0xcbuy; 0x68uy; 0x60uy; 0x69uy; 0x37uy; 0x38uy; 0x0duy;
            0xb2uy; 0xeauy; 0xaauy; 0x70uy; 0x7buy; 0x4cuy; 0x41uy; 0x85uy;
            0xc3uy; 0x2euy; 0xdduy; 0xcduy; 0xd3uy; 0x06uy; 0x70uy; 0x5euy;
            0x4duy; 0xc1uy; 0xffuy; 0xc8uy; 0x72uy; 0xeeuy; 0xeeuy; 0x47uy;
            0x5auy; 0x64uy; 0xdfuy; 0xacuy; 0x86uy; 0xabuy; 0xa4uy; 0x1cuy;
            0x06uy; 0x18uy; 0x98uy; 0x3fuy; 0x87uy; 0x41uy; 0xc5uy; 0xefuy;
            0x68uy; 0xd3uy; 0xa1uy; 0x01uy; 0xe8uy; 0xa3uy; 0xb8uy; 0xcauy;
            0xc6uy; 0x0cuy; 0x90uy; 0x5cuy; 0x15uy; 0xfcuy; 0x91uy; 0x08uy;
            0x40uy; 0xb9uy; 0x4cuy; 0x00uy; 0xa0uy; 0xb9uy; 0xd0uy]

let sig4 = [0x0auy; 0xabuy; 0x4cuy; 0x90uy; 0x05uy; 0x01uy; 0xb3uy; 0xe2uy;
            0x4duy; 0x7cuy; 0xdfuy; 0x46uy; 0x63uy; 0x32uy; 0x6auy; 0x3auy;
            0x87uy; 0xdfuy; 0x5euy; 0x48uy; 0x43uy; 0xb2uy; 0xcbuy; 0xdbuy;
            0x67uy; 0xcbuy; 0xf6uy; 0xe4uy; 0x60uy; 0xfeuy; 0xc3uy; 0x50uy;
            0xaauy; 0x53uy; 0x71uy; 0xb1uy; 0x50uy; 0x8fuy; 0x9fuy; 0x45uy;
            0x28uy; 0xecuy; 0xeauy; 0x23uy; 0xc4uy; 0x36uy; 0xd9uy; 0x4buy;
            0x5euy; 0x8fuy; 0xcduy; 0x4fuy; 0x68uy; 0x1euy; 0x30uy; 0xa6uy;
            0xacuy; 0x00uy; 0xa9uy; 0x70uy; 0x4auy; 0x18uy; 0x8auy; 0x03uy]

let test() =
  let sk1 = createL sk1 in
  let pk1 = createL pk1 in
  let msg1 = createL msg1 in
  let sig1 = createL sig1 in
  let sk2 = createL sk2 in
  let pk2 = createL pk2 in
  let msg2 = createL msg2 in
  let sig2 = createL sig2 in
  let sk3 = createL sk3 in
  let pk3 = createL pk3 in
  let msg3 = createL msg3 in
  let sig3 = createL sig3 in
  let sk4 = createL sk4 in
  let pk4 = createL pk4 in
  let msg4 = createL msg4 in
  let sig4 = createL sig4 in
  sign sk1 msg1 = sig1 && verify pk1 msg1 sig1 = true &&
  sign sk2 msg2 = sig2 && verify pk2 msg2 sig2 = true &&
  sign sk3 msg3 = sig3 && verify pk3 msg3 sig3 = true &&
  sign sk4 msg4 = sig4 && verify pk4 msg4 sig4 = true
