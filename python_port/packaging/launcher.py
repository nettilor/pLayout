"""PyInstaller entry point. PyInstaller cannot use a console-script entry point, so this
tiny script is what the frozen executable runs: it just hands over to `playout.app.main`."""
import sys

from playout.app import main

if __name__ == "__main__":
    sys.exit(main(sys.argv))
