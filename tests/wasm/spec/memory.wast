;; Memory load and store tests

(module
  (memory 1)
  (func (export "store_i32") (param i32 i32)
    local.get 0
    local.get 1
    i32.store)
  (func (export "load_i32") (param i32) (result i32)
    local.get 0
    i32.load)
  (func (export "store_i64") (param i32 i64)
    local.get 0
    local.get 1
    i64.store)
  (func (export "load_i64") (param i32) (result i64)
    local.get 0
    i64.load)
  (func (export "store8") (param i32 i32)
    local.get 0
    local.get 1
    i32.store8)
  (func (export "load8_s") (param i32) (result i32)
    local.get 0
    i32.load8_s)
  (func (export "load8_u") (param i32) (result i32)
    local.get 0
    i32.load8_u)
  (func (export "store16") (param i32 i32)
    local.get 0
    local.get 1
    i32.store16)
  (func (export "load16_s") (param i32) (result i32)
    local.get 0
    i32.load16_s)
  (func (export "load16_u") (param i32) (result i32)
    local.get 0
    i32.load16_u)
  (func (export "memory_size") (result i32)
    memory.size)
  (func (export "memory_grow") (param i32) (result i32)
    local.get 0
    memory.grow)
)

;; Basic load/store
(assert_return (invoke "store_i32" (i32.const 0) (i32.const 42)))
(assert_return (invoke "load_i32" (i32.const 0)) (i32.const 42))
(assert_return (invoke "store_i32" (i32.const 100) (i32.const 1234567890)))
(assert_return (invoke "load_i32" (i32.const 100)) (i32.const 1234567890))
(assert_return (invoke "store_i32" (i32.const 0) (i32.const -1)))
(assert_return (invoke "load_i32" (i32.const 0)) (i32.const -1))

;; i64 load/store
(assert_return (invoke "store_i64" (i32.const 0) (i64.const 9223372036854775807)))
(assert_return (invoke "load_i64" (i32.const 0)) (i64.const 9223372036854775807))

;; Byte load/store
(assert_return (invoke "store8" (i32.const 0) (i32.const 255)))
(assert_return (invoke "load8_u" (i32.const 0)) (i32.const 255))
(assert_return (invoke "load8_s" (i32.const 0)) (i32.const -1))
(assert_return (invoke "store8" (i32.const 0) (i32.const 128)))
(assert_return (invoke "load8_u" (i32.const 0)) (i32.const 128))
(assert_return (invoke "load8_s" (i32.const 0)) (i32.const -128))

;; 16-bit load/store
(assert_return (invoke "store16" (i32.const 0) (i32.const 65535)))
(assert_return (invoke "load16_u" (i32.const 0)) (i32.const 65535))
(assert_return (invoke "load16_s" (i32.const 0)) (i32.const -1))

;; Memory size and grow
(assert_return (invoke "memory_size") (i32.const 1))
(assert_return (invoke "memory_grow" (i32.const 1)) (i32.const 1))
(assert_return (invoke "memory_size") (i32.const 2))

;; Out-of-bounds trap
(assert_trap (invoke "load_i32" (i32.const 131072)) "out of bounds")
(assert_trap (invoke "store_i32" (i32.const 131072) (i32.const 0)) "out of bounds")
