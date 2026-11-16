# Build Tiny Tapeout with OpenLane 2

## Environment setup

```bash
export TT_CONFIG=ihp-sg13g2.yaml
export PDK=ihp-sg13g2
export PDK_ROOT=`pwd`/IHP-Open-PDK
export OPENLANE2_ROOT=`pwd`/openlane2
```

Make sure to setup Nix for openlane2, as explained [here](https://openlane2.readthedocs.io/en/latest/getting_started/nix_installation/index.html).

## Repository setup

First, make sure that you have checked out the submodules:

```bash
git submodule update --init
```

Then install all the Python dependencies. You may want to use a virtual enviroment (venv or similar).

```bash
pip install -r tt-multiplexer/py/requirements.txt -r tt/requirements.txt
```

## Fetching the projects

Run the following commands to generate the configuration for building Tiny Tapeout:

```bash
python tt/configure.py --update-shuttle
```

## Harden

```bash
nix-shell ${OPENLANE2_ROOT}/shell.nix --run "cd tt/rom && python build.ihp-sg13g2.py"
nix-shell ${OPENLANE2_ROOT}/shell.nix --run "cd tt-multiplexer/ol2/tt_ctrl && python build.py"
nix-shell ${OPENLANE2_ROOT}/shell.nix --run "cd tt-multiplexer/ol2/tt_mux && python build.py"
python tt/configure.py --copy-macros
nix-shell ${OPENLANE2_ROOT}/shell.nix --run "cd tt-multiplexer/ol2/tt_top && python build.py"
```

You'll find the final GDS in `tt-multiplexer/ol2/tt_top/runs/RUN_*/final/gds/openframe_project_wrapper.gds`. To copy it (along with the lef, gl verilog, and spef files), run:

```bash
python tt/configure.py --copy-final-results
```
