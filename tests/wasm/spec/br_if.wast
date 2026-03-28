;; br_if conditional branch tests

(module
  (func (export "br_if_taken") (param i32) (result i32)
    block (result i32)
      i32.const 1
      local.get 0
      br_if 0
      drop
      i32.const 0
    end)
  (func (export "abs") (param i32) (result i32)
    local.get 0
    i32.const 0
    i32.ge_s
    if (result i32)
      local.get 0
    else
      i32.const 0
      local.get 0
      i32.sub
    end)
  (func (export "max") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.ge_s
    if (result i32)
      local.get 0
    else
      local.get 1
    end)
  (func (export "min") (param i32 i32) (result i32)
    local.get 0
    local.get 1
    i32.le_s
    if (result i32)
      local.get 0
    else
      local.get 1
    end)
  (func (export "count_down") (param i32) (result i32)
    (local i32)
    local.get 0
    local.set 1
    block
      loop
        local.get 1
        i32.eqz
        br_if 1
        local.get 1
        i32.const 1
        i32.sub
        local.set 1
        br 0
      end
    end
    local.get 1)
  (func (export "find_first") (param i32 i32) (result i32)
    ;; find first occurrence of p0 in range [0, p1)
    ;; returns index or -1
    (local i32)
    i32.const -1
    local.set 2
    block
      loop
        local.get 2
        i32.const 1
        i32.add
        local.tee 2
        local.get 1
        i32.ge_s
        br_if 1
        local.get 2
        local.get 0
        i32.eq
        br_if 1
        br 0
      end
    end
    local.get 2
    local.get 1
    i32.ge_s
    if (result i32)
      i32.const -1
    else
      local.get 2
    end)
)

(assert_return (invoke "br_if_taken" (i32.const 1)) (i32.const 1))
(assert_return (invoke "br_if_taken" (i32.const 0)) (i32.const 0))
(assert_return (invoke "abs" (i32.const 5)) (i32.const 5))
(assert_return (invoke "abs" (i32.const -5)) (i32.const 5))
(assert_return (invoke "abs" (i32.const 0)) (i32.const 0))
(assert_return (invoke "max" (i32.const 5) (i32.const 3)) (i32.const 5))
(assert_return (invoke "max" (i32.const 3) (i32.const 5)) (i32.const 5))
(assert_return (invoke "max" (i32.const 5) (i32.const 5)) (i32.const 5))
(assert_return (invoke "min" (i32.const 5) (i32.const 3)) (i32.const 3))
(assert_return (invoke "min" (i32.const 3) (i32.const 5)) (i32.const 3))
(assert_return (invoke "count_down" (i32.const 0)) (i32.const 0))
(assert_return (invoke "count_down" (i32.const 5)) (i32.const 0))
(assert_return (invoke "count_down" (i32.const 100)) (i32.const 0))
(assert_return (invoke "find_first" (i32.const 3) (i32.const 5)) (i32.const 3))
(assert_return (invoke "find_first" (i32.const 0) (i32.const 5)) (i32.const 0))
(assert_return (invoke "find_first" (i32.const 10) (i32.const 5)) (i32.const -1))
