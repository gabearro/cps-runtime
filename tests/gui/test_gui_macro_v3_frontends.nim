import cps/gui
import cps/gui/macros

guiBlock(BlockFrontendModule, """
component Root {
  Text("Hello")
}

app MacroFrontend {
  state {
    count: Int = 0
  }

  action Increment owner swift

  reducer {
    on Increment {
      set count = count + 1
    }
  }
}
""")

guiBuild(BuildFrontendModule, """
component Root {
  Text("Hello")
}

app MacroFrontend {
  state {
    count: Int = 0
  }

  action Increment owner swift

  reducer {
    on Increment {
      set count = count + 1
    }
  }
}
""")

let leftSig = BlockFrontendModuleGuiIrSignature()
let rightSig = BuildFrontendModuleGuiIrSignature()
assert leftSig == rightSig
assert not checkBlockFrontendModuleGui().hasErrors
assert not checkBuildFrontendModuleGui().hasErrors

echo "PASS: GUI macro v3 frontends"
