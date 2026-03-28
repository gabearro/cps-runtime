;; loop and iteration tests

(module
  (func (export "count_to") (param i32) (result i32)
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
  (func (export "sum_to") (param i32) (result i32)
    (local i32)
    (local i32)
    i32.const 0
    local.set 1
    i32.const 0
    local.set 2
    block
      loop
        local.get 2
        local.get 0
        i32.gt_s
        br_if 1
        local.get 1
        local.get 2
        i32.add
        local.set 1
        local.get 2
        i32.const 1
        i32.add
        local.set 2
        br 0
      end
    end
    local.get 1)
  (func (export "factorial") (param i32) (result i32)
    (local i32)
    i32.const 1
    local.set 1
    block
      loop
        local.get 0
        i32.const 1
        i32.le_s
        br_if 1
        local.get 1
        local.get 0
        i32.mul
        local.set 1
        local.get 0
        i32.const 1
        i32.sub
        local.set 0
        br 0
      end
    end
    local.get 1)
  (func (export "loop_break") (result i32)
    (local i32)
    i32.const 0
    local.set 0
    block
      loop
        local.get 0
        i32.const 5
        i32.eq
        br_if 1
        local.get 0
        i32.const 1
        i32.add
        local.set 0
        br 0
      end
    end
    local.get 0)
)

(assert_return (invoke "count_to" (i32.const 0)) (i32.const 0))
(assert_return (invoke "count_to" (i32.const 1)) (i32.const 1))
(assert_return (invoke "count_to" (i32.const 5)) (i32.const 5))
(assert_return (invoke "count_to" (i32.const 10)) (i32.const 10))
(assert_return (invoke "sum_to" (i32.const 0)) (i32.const 0))
(assert_return (invoke "sum_to" (i32.const 1)) (i32.const 1))
(assert_return (invoke "sum_to" (i32.const 5)) (i32.const 15))
(assert_return (invoke "sum_to" (i32.const 10)) (i32.const 55))
(assert_return (invoke "factorial" (i32.const 0)) (i32.const 1))
(assert_return (invoke "factorial" (i32.const 1)) (i32.const 1))
(assert_return (invoke "factorial" (i32.const 5)) (i32.const 120))
(assert_return (invoke "factorial" (i32.const 10)) (i32.const 3628800))
(assert_return (invoke "loop_break") (i32.const 5))
