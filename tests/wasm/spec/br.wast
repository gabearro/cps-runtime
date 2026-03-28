;; br and br_table tests

(module
  (func (export "br_block") (result i32)
    block (result i32)
      i32.const 42
      br 0
      i32.const 0
    end)
  (func (export "br_nested") (result i32)
    block (result i32)
      block
        i32.const 1
        br 1
      end
      i32.const 0
    end)
  (func (export "br_table_0") (param i32) (result i32)
    block (result i32)
      block (result i32)
        block (result i32)
          i32.const 10
          local.get 0
          br_table 0 1 2
        end
        i32.const 100
        i32.add
      end
      i32.const 200
      i32.add
    end)
  (func (export "select_br") (param i32) (result i32)
    block (result i32)
      i32.const 0
      local.get 0
      if
        drop
        i32.const 1
        br 1
      end
      drop
      i32.const 2
    end)
  (func (export "br_loop_count") (param i32) (result i32)
    (local i32)
    i32.const 0
    local.set 1
    block
      loop
        local.get 1
        local.get 0
        i32.ge_s
        br_if 1
        local.get 1
        i32.const 1
        i32.add
        local.set 1
        br 0
      end
    end
    local.get 1)
)

(assert_return (invoke "br_block") (i32.const 42))
(assert_return (invoke "br_nested") (i32.const 1))
(assert_return (invoke "br_table_0" (i32.const 0)) (i32.const 310))
(assert_return (invoke "br_table_0" (i32.const 1)) (i32.const 210))
(assert_return (invoke "br_table_0" (i32.const 2)) (i32.const 10))
(assert_return (invoke "br_table_0" (i32.const 99)) (i32.const 10))
(assert_return (invoke "select_br" (i32.const 1)) (i32.const 1))
(assert_return (invoke "select_br" (i32.const 0)) (i32.const 2))
(assert_return (invoke "br_loop_count" (i32.const 0)) (i32.const 0))
(assert_return (invoke "br_loop_count" (i32.const 5)) (i32.const 5))
(assert_return (invoke "br_loop_count" (i32.const 10)) (i32.const 10))
