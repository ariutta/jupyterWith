{ overlays ? []
, config ? {}
, pkgs ? import ./nix { inherit config overlays; }
, directory ? null
, serverextensions ? []
}:

with (import ./lib/directory.nix { inherit pkgs; });
with (import ./lib/docker.nix { inherit pkgs; });
with pkgs.lib;

let
  # Kernel generators.
  kernels = pkgs.callPackage ./kernels {};
  kernelsString = concatMapStringsSep ":" (k: "${k.spec}");

  # Python version setup.
  python3 = pkgs.python3Packages;

  # Default configuration.
  defaultDirectory = "${python3.jupyterlab}/share/jupyter/lab";
  defaultKernels = [ (kernels.iPythonWith {}) ];
  defaultExtraPackages = p: [];

  getDirectory = {
    directory ? "${defaultDirectory}"
  }: directory;

  myDirectory = (getDirectory { directory = directory; });

  # JupyterLab with the appropriate kernel and directory setup.
  jupyterlabWith = {
    directory ? myDirectory,
    kernels ? defaultKernels,
    extraPackages ? defaultExtraPackages
    }:
    let
      # PYTHONPATH setup for JupyterLab
      pythonPath = python3.makePythonPath ([
        python3.ipykernel
        python3.jupyter_contrib_core
        python3.jupyter_nbextensions_configurator
        python3.tornado
      ] ++
      # TODO: I seem to need to use this for now:
      (attrsets.attrVals serverextensions python3)
      # but wouldn't the following the preferable?
      #serverextensions
      );

      # JupyterLab executable wrapped with suitable environment variables.
      jupyterlab = python3.toPythonModule (
        python3.jupyterlab.overridePythonAttrs (oldAttrs: {
          makeWrapperArgs = [
            # TODO: not sure whether these are all needed
            "--set JUPYTER_CONFIG_DIR ${myDirectory}/config"
            "--set JUPYTER_DATA_DIR ${myDirectory}/data"
            "--set JUPYTER_RUNTIME_DIR ${myDirectory}/runtime"
            "--set JUPYTERLAB_DIR ${myDirectory}/lab"
            "--set JUPYTER_PATH ${kernelsString kernels}"
            "--set PYTHONPATH ${pythonPath}"
          ];
        })
      );

      # Shell with the appropriate JupyterLab, launching it at startup.
      env = pkgs.mkShell {
        name = "jupyterlab-shell";
        buildInputs =
          [ jupyterlab generateDirectory pkgs.nodejs ] ++
          (map (k: k.runtimePackages) kernels) ++
          (extraPackages pkgs);
        shellHook = ''
          # this is needed in order that tools like curl and git can work with SSL
          if [ ! -f "$SSL_CERT_FILE" ] || [ ! -f "$NIX_SSL_CERT_FILE" ]; then
            candidate_ssl_cert_file=""
            if [ -f "$SSL_CERT_FILE" ]; then
              candidate_ssl_cert_file="$SSL_CERT_FILE"
            elif [ -f "$NIX_SSL_CERT_FILE" ]; then
              candidate_ssl_cert_file="$NIX_SSL_CERT_FILE"
            else
              candidate_ssl_cert_file="/etc/ssl/certs/ca-bundle.crt"
            fi
            if [ -f "$candidate_ssl_cert_file" ]; then
                export SSL_CERT_FILE="$candidate_ssl_cert_file"
                export NIX_SSL_CERT_FILE="$candidate_ssl_cert_file"
            else
              echo "Cannot find a valid SSL certificate file. curl will not work." 1>&2
            fi
          fi

          export JUPYTER_PATH=${kernelsString kernels}
          export JUPYTER_CONFIG_DIR=${myDirectory}/config
          export JUPYTER_DATA_DIR=${myDirectory}/data
          export JUPYTER_RUNTIME_DIR=${myDirectory}/runtime
          export JUPYTERLAB_DIR=${myDirectory}/lab
          export JUPYTERLAB=${jupyterlab}

          if [ ! -d "${myDirectory}" ]; then
            mkdir -p "$JUPYTER_CONFIG_DIR"
            mkdir -p "$JUPYTER_DATA_DIR"
            mkdir -p "$JUPYTER_RUNTIME_DIR"
            mkdir -p "$JUPYTERLAB_DIR"
          fi
        '';
      };
    in
      jupyterlab.override (oldAttrs: {
        passthru = oldAttrs.passthru or {} // { inherit env; };
      });
in
  { inherit jupyterlabWith kernels mkDirectoryWith mkDockerImage; }
