;; i32 arithmetic, comparison, and bitwise operations

(module
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)
  (func (export "sub") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.sub)
  (func (export "mul") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.mul)
  (func (export "div_s") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.div_s)
  (func (export "div_u") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.div_u)
  (func (export "rem_s") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.rem_s)
  (func (export "rem_u") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.rem_u)
  (func (export "and") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.and)
  (func (export "or") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.or)
  (func (export "xor") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.xor)
  (func (export "shl") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.shl)
  (func (export "shr_s") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.shr_s)
  (func (export "shr_u") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.shr_u)
  (func (export "rotl") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.rotl)
  (func (export "rotr") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.rotr)
  (func (export "clz") (param i32) (result i32)
    local.get 0
    i32.clz)
  (func (export "ctz") (param i32) (result i32)
    local.get 0
    i32.ctz)
  (func (export "popcnt") (param i32) (result i32)
    local.get 0
    i32.popcnt)
  (func (export "eqz") (param i32) (result i32)
    local.get 0
    i32.eqz)
  (func (export "eq") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.eq)
  (func (export "ne") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.ne)
  (func (export "lt_s") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.lt_s)
  (func (export "lt_u") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.lt_u)
  (func (export "gt_s") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.gt_s)
  (func (export "gt_u") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.gt_u)
  (func (export "le_s") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.le_s)
  (func (export "le_u") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.le_u)
  (func (export "ge_s") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.ge_s)
  (func (export "ge_u") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.ge_u)
)

;; Basic arithmetic
(assert_return (invoke "add" (i32.const 1) (i32.const 1)) (i32.const 2))
(assert_return (invoke "add" (i32.const 0) (i32.const 0)) (i32.const 0))
(assert_return (invoke "add" (i32.const -1) (i32.const 1)) (i32.const 0))
(assert_return (invoke "add" (i32.const 2147483647) (i32.const 1)) (i32.const -2147483648))
(assert_return (invoke "sub" (i32.const 10) (i32.const 3)) (i32.const 7))
(assert_return (invoke "sub" (i32.const 0) (i32.const 1)) (i32.const -1))
(assert_return (invoke "sub" (i32.const -2147483648) (i32.const 1)) (i32.const 2147483647))
(assert_return (invoke "mul" (i32.const 3) (i32.const 4)) (i32.const 12))
(assert_return (invoke "mul" (i32.const -1) (i32.const -1)) (i32.const 1))
(assert_return (invoke "mul" (i32.const 100) (i32.const 0)) (i32.const 0))

;; Division
(assert_return (invoke "div_s" (i32.const 10) (i32.const 3)) (i32.const 3))
(assert_return (invoke "div_s" (i32.const -10) (i32.const 3)) (i32.const -3))
(assert_return (invoke "div_u" (i32.const 10) (i32.const 3)) (i32.const 3))
(assert_return (invoke "rem_s" (i32.const 10) (i32.const 3)) (i32.const 1))
(assert_return (invoke "rem_s" (i32.const -10) (i32.const 3)) (i32.const -1))
(assert_return (invoke "rem_u" (i32.const 10) (i32.const 3)) (i32.const 1))
(assert_trap (invoke "div_s" (i32.const 1) (i32.const 0)) "integer divide by zero")
(assert_trap (invoke "div_u" (i32.const 1) (i32.const 0)) "integer divide by zero")
(assert_trap (invoke "rem_s" (i32.const 1) (i32.const 0)) "integer divide by zero")
(assert_trap (invoke "rem_u" (i32.const 1) (i32.const 0)) "integer divide by zero")

;; Bitwise
(assert_return (invoke "and" (i32.const 0xFF) (i32.const 0x0F)) (i32.const 15))
(assert_return (invoke "or" (i32.const 0xF0) (i32.const 0x0F)) (i32.const 255))
(assert_return (invoke "xor" (i32.const 0xFF) (i32.const 0x0F)) (i32.const 240))
(assert_return (invoke "shl" (i32.const 1) (i32.const 4)) (i32.const 16))
(assert_return (invoke "shr_s" (i32.const -16) (i32.const 2)) (i32.const -4))
(assert_return (invoke "shr_u" (i32.const -1) (i32.const 1)) (i32.const 2147483647))
(assert_return (invoke "rotl" (i32.const 1) (i32.const 1)) (i32.const 2))
(assert_return (invoke "rotr" (i32.const 2) (i32.const 1)) (i32.const 1))

;; Unary
(assert_return (invoke "clz" (i32.const 0)) (i32.const 32))
(assert_return (invoke "clz" (i32.const 1)) (i32.const 31))
(assert_return (invoke "clz" (i32.const -1)) (i32.const 0))
(assert_return (invoke "ctz" (i32.const 0)) (i32.const 32))
(assert_return (invoke "ctz" (i32.const 1)) (i32.const 0))
(assert_return (invoke "ctz" (i32.const -2147483648)) (i32.const 31))
(assert_return (invoke "popcnt" (i32.const 0)) (i32.const 0))
(assert_return (invoke "popcnt" (i32.const -1)) (i32.const 32))
(assert_return (invoke "popcnt" (i32.const 255)) (i32.const 8))

;; Comparisons
(assert_return (invoke "eqz" (i32.const 0)) (i32.const 1))
(assert_return (invoke "eqz" (i32.const 1)) (i32.const 0))
(assert_return (invoke "eq" (i32.const 5) (i32.const 5)) (i32.const 1))
(assert_return (invoke "eq" (i32.const 5) (i32.const 6)) (i32.const 0))
(assert_return (invoke "ne" (i32.const 5) (i32.const 6)) (i32.const 1))
(assert_return (invoke "lt_s" (i32.const -1) (i32.const 0)) (i32.const 1))
(assert_return (invoke "lt_u" (i32.const 0) (i32.const -1)) (i32.const 1))
(assert_return (invoke "gt_s" (i32.const 1) (i32.const 0)) (i32.const 1))
(assert_return (invoke "le_s" (i32.const 5) (i32.const 5)) (i32.const 1))
(assert_return (invoke "ge_s" (i32.const 5) (i32.const 4)) (i32.const 1))
