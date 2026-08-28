import QtQuick
import Quickshell.Io

Item {
  id: root

  property var manifest: null
  readonly property string plonkPath: manifest && manifest.__sourceDir
    ? manifest.__sourceDir + "/plonk"
    : ""
  property int lastExitCode: -1

  function startWatcher() {
    if (root.plonkPath !== "" && !watcher.running)
      watcher.running = true
  }

  onPlonkPathChanged: startWatcher()
  Component.onCompleted: startWatcher()
  Component.onDestruction: {
    restartTimer.stop()
    watcher.running = false
  }

  Process {
    id: watcher
    command: root.plonkPath === ""
      ? []
      : ["setpriv", "--pdeathsig", "TERM", root.plonkPath, "--watch"]
    onExited: function(exitCode) {
      root.lastExitCode = exitCode
      if (root.plonkPath !== "")
        restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 5000
    repeat: false
    onTriggered: root.startWatcher()
  }

  Process {
    id: compactProcess
    command: root.plonkPath === "" ? [] : [root.plonkPath]
  }

  IpcHandler {
    target: "plonk"

    function status(): string {
      return JSON.stringify({
        watching: watcher.running,
        compacting: compactProcess.running,
        lastExitCode: root.lastExitCode
      })
    }

    function compact(): string {
      if (root.plonkPath === "") return "unavailable"
      if (compactProcess.running) return "busy"
      compactProcess.running = true
      return "started"
    }
  }
}
