;; block, if/else, and structured control flow tests

(module
  (func (export "block_result") (result i32)
    block (result i32)
      i32.const 42
    end)
  (func (export "block_br") (result i32)
    block (result i32)
      i32.const 1
      br 0
      i32.const 2
    end)
  (func (export "if_true") (param i32) (result i32)
    local.get 0
    if (result i32)
      i32.const 1
    else
      i32.const 0
    end)
  (func (export "if_no_else") (param i32) (result i32)
    i32.const 0
    local.get 0
    if
      drop
      i32.const 1
    end)
  (func (export "nested_if") (param i32 i32) (result i32)
    local.get 0
    if (result i32)
      local.get 1
      if (result i32)
        i32.const 3
      else
        i32.const 2
      end
    else
      i32.const 0
    end)
  (func (export "select_val") (param i32 i32 i32) (result i32)
    local.get 0
    local.get 1
    local.get 2
    select)
  (func (export "block_nop") (result i32)
    block
    end
    i32.const 99)
  (func (export "nested_block_br") (result i32)
    block (result i32)
      block (result i32)
        i32.const 5
        br 1
      end
      i32.const 10
    end)
)

(assert_return (invoke "block_result") (i32.const 42))
(assert_return (invoke "block_br") (i32.const 1))
(assert_return (invoke "if_true" (i32.const 1)) (i32.const 1))
(assert_return (invoke "if_true" (i32.const 0)) (i32.const 0))
(assert_return (invoke "if_true" (i32.const -1)) (i32.const 1))
(assert_return (invoke "if_no_else" (i32.const 1)) (i32.const 1))
(assert_return (invoke "if_no_else" (i32.const 0)) (i32.const 0))
(assert_return (invoke "nested_if" (i32.const 1) (i32.const 1)) (i32.const 3))
(assert_return (invoke "nested_if" (i32.const 1) (i32.const 0)) (i32.const 2))
(assert_return (invoke "nested_if" (i32.const 0) (i32.const 1)) (i32.const 0))
(assert_return (invoke "select_val" (i32.const 1) (i32.const 2) (i32.const 1)) (i32.const 1))
(assert_return (invoke "select_val" (i32.const 1) (i32.const 2) (i32.const 0)) (i32.const 2))
(assert_return (invoke "block_nop") (i32.const 99))
(assert_return (invoke "nested_block_br") (i32.const 5))
