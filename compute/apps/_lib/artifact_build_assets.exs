# Preload with elixir -r before invoking Mix. Unlike mix run/app.config, this
# task does not evaluate production runtime config. Prepare tools before the
# expensive compilation phase; reuse them only within this disposable build.
defmodule Mix.Tasks.Infra.Assets do
  use Mix.Task
  @shortdoc "Builds release assets without production runtime configuration"

  def run(args) do
    version = Application.get_env(:tailwind, :version)

    adapter_path =
      if version && !Application.get_env(:tailwind, :path) do
        package =
          if Version.parse!(version).major >= 4,
            do: "@tailwindcss/cli@#{version}",
            else: "tailwindcss@#{version}"

        prefix = Path.expand("_build/infra-tailwind")
        cli = Path.join(prefix, "node_modules/.bin/tailwindcss")
        marker = Path.join(prefix, ".infra-package")
        unless File.exists?(cli) && File.read(marker) == {:ok, package} do
          {_, status} = System.cmd("npm", ["install", "--prefix", prefix, "--no-audit",
            "--no-fund", "--save-exact", package], into: IO.stream(:stdio, :line), stderr_to_stdout: true)
          if status != 0, do: raise("native Tailwind CLI installation failed")
          File.write!(marker, package)
        end
        Application.put_env(:tailwind, :path, cli)
        Application.put_env(:tailwind, :version_check, false)
        Path.join(prefix, "node_modules/tailwindcss")
      end

    unless "--prepare-only" in args do
      Mix.Task.run("loadpaths")
      Mix.Task.run("assets.setup")

      # npm ci stays authoritative for application dependencies. Link only the
      # build tool required by @import "tailwindcss" after setup completes.
      if adapter_path do
        File.mkdir_p!("assets/node_modules")
        target = "assets/node_modules/tailwindcss"
        unless File.exists?(target), do: File.ln_s!(adapter_path, target)
      end

      # Phoenix generates phoenix-colocated/<app> JavaScript during project
      # compilation. Compile after setup, before esbuild; this is still a
      # build-only task and does not load production runtime configuration.
      if System.get_env("INFRA_PROGRESS_JSONL") == "1" do
        started = System.monotonic_time(:nanosecond)
        status_key = {__MODULE__, :project_compile_status, make_ref()}
        Process.put(status_key, "failed")
        try do
          result = Mix.Task.run("compile")
          Process.put(status_key, "completed")
          result
        after
          # Contain only diagnostic work, never the compiler exception.
          try do
            elapsed = (System.monotonic_time(:nanosecond) - started) / 1_000_000_000
            status = Process.delete(status_key)
            IO.puts(:stderr, "{\"event\":\"infra.phase_duration\",\"operation\":\"artifact.build\",\"workload\":null,\"phase\":\"project-compile\",\"parent\":\"asset-build\",\"status\":\"#{status}\",\"duration_seconds\":#{elapsed},\"reason\":null}")
          rescue
            _ -> :ok
          catch
            :exit, _ -> :ok
          after
            Process.delete(status_key)
          end
        end
      else
        Mix.Task.run("compile")
      end
      prepare_plugin_inputs()
      Mix.Task.run("assets.deploy")
    end
  end

  # Phoenix's vendored DaisyUI bundles export {default: optionsFunction}.
  # Node's CJS import adds another default layer, hiding the options marker.
  # Generate wrappers and an adjacent CSS input; leave original source intact.
  defp prepare_plugin_inputs do
    for {name, profile} <- Application.get_all_env(:tailwind),
        is_list(profile), Keyword.keyword?(profile),
        args = Keyword.get(profile, :args), is_list(args),
        input = Enum.find_value(args, fn
          "--input=" <> value -> value
          _ -> nil
        end), is_binary(input) do
      path = Path.expand(input, Keyword.get(profile, :cd, File.cwd!()))
      if File.regular?(path) do
        original = File.read!(path)
        css = Enum.reduce(["daisyui", "daisyui-theme"], original, fn plugin, css ->
          reference = ~s(@plugin "../vendor/#{plugin}")
          source = Path.expand("../vendor/#{plugin}.js", Path.dirname(path))
          if String.contains?(css, reference) && File.regular?(source) &&
              String.contains?(File.read!(source), "module.exports = __toCommonJS(") do
            shim = Path.join(Path.dirname(source), ".infra-#{plugin}.cjs")
            File.write!(shim, ~s|module.exports = require("./#{plugin}.js").default;\n|)
            String.replace(css, reference, ~s(@plugin "../vendor/.infra-#{plugin}.cjs"))
          else
            css
          end
        end)
        if css != original do
          generated = Path.join(Path.dirname(path), ".infra-" <> Path.basename(path))
          File.write!(generated, css)
          args = Enum.map(args, fn
            "--input=" <> _ -> "--input=" <> generated
            arg -> arg
          end)
          Application.put_env(:tailwind, name, Keyword.put(profile, :args, args))
        end
      end
    end
  end
end
