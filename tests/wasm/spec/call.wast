;; Function call tests

(module
  (func (export "const42") (result i32)
    i32.const 42)
  (func (export "identity") (param i32) (result i32)
    local.get 0)
  (func (export "add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)
  (func $double (param i32) (result i32)
    local.get 0
    i32.const 2
    i32.mul)
  (func (export "call_double") (param i32) (result i32)
    local.get 0
    call $double)
  (func $add_internal (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.add)
  (func (export "call_add") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    call $add_internal)
  (func $fib (param i32) (result i32)
    local.get 0
    i32.const 2
    i32.lt_s
    if (result i32)
      local.get 0
    else
      local.get 0
      i32.const 1
      i32.sub
      call $fib
      local.get 0
      i32.const 2
      i32.sub
      call $fib
      i32.add
    end)
  (func (export "fib") (param i32) (result i32)
    local.get 0
    call $fib)
  (func $fact (param i32) (result i32)
    local.get 0
    i32.const 1
    i32.le_s
    if (result i32)
      i32.const 1
    else
      local.get 0
      local.get 0
      i32.const 1
      i32.sub
      call $fact
      i32.mul
    end)
  (func (export "factorial") (param i32) (result i32)
    local.get 0
    call $fact)
)

(assert_return (invoke "const42") (i32.const 42))
(assert_return (invoke "identity" (i32.const 5)) (i32.const 5))
(assert_return (invoke "identity" (i32.const -1)) (i32.const -1))
(assert_return (invoke "add" (i32.const 3) (i32.const 4)) (i32.const 7))
(assert_return (invoke "call_double" (i32.const 5)) (i32.const 10))
(assert_return (invoke "call_double" (i32.const 0)) (i32.const 0))
(assert_return (invoke "call_double" (i32.const -3)) (i32.const -6))
(assert_return (invoke "call_add" (i32.const 10) (i32.const 20)) (i32.const 30))
(assert_return (invoke "fib" (i32.const 0)) (i32.const 0))
(assert_return (invoke "fib" (i32.const 1)) (i32.const 1))
(assert_return (invoke "fib" (i32.const 2)) (i32.const 1))
(assert_return (invoke "fib" (i32.const 5)) (i32.const 5))
(assert_return (invoke "fib" (i32.const 10)) (i32.const 55))
(assert_return (invoke "factorial" (i32.const 0)) (i32.const 1))
(assert_return (invoke "factorial" (i32.const 1)) (i32.const 1))
(assert_return (invoke "factorial" (i32.const 5)) (i32.const 120))
(assert_return (invoke "factorial" (i32.const 10)) (i32.const 3628800))
