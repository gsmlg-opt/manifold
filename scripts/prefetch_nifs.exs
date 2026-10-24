# OTP 28.5.0.6 added a 10 KiB httpc response-header limit. These downloaders
# do not expose its per-request override; seed their documented archive caches
# with curl instead. Each loader still verifies the package's checksum itself.
defmodule Manifold.CI.PrefetchNIFs do
  def run do
    unless :os.type() == {:unix, :linux} and
             String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "x86_64-") and
             match?({"glibc " <> _, 0}, System.cmd("getconf", ["GNU_LIBC_VERSION"])) do
      raise "native archive prefetch supports only x86_64 Linux glibc runners"
    end

    root = Path.expand("..", __DIR__)
    deps = System.get_env("MIX_DEPS_PATH") || Path.join(root, "deps")
    lock = Mix.Dep.Lock.read(Path.join(root, "mix.lock"))
    rustler_cache = System.fetch_env!("RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH")
    zigler_cache = System.fetch_env!("ZIGLER_PRECOMPILED_GLOBAL_CACHE_PATH")
    make_cache = System.fetch_env!("ELIXIR_MAKE_CACHE_DIR")
    bundler_url = "https://github.com/duskmoon-dev/duskmoon-bundler/releases/download/v"

    packages = [
      {"rrule", "https://github.com/mfeckie/rrule/releases/download/", rustler_cache},
      {"mdex_native", "https://github.com/leandrocp/mdex_native/releases/download/v",
       rustler_cache},
      {"duskmoon_oxc", bundler_url, rustler_cache},
      {"duskmoon_oxide", bundler_url, rustler_cache},
      {"duskmoon_vize", bundler_url, rustler_cache},
      {"duskmoon_quickbeam", bundler_url, zigler_cache},
      {"lazy_html", "https://github.com/dashbitco/lazy_html/releases/download/v", make_cache}
    ]

    # Validate every package's manifest before starting any downloads. Include
    # all shipped NIF/CPU variants so the loader keeps selecting its own variant.
    archives =
      Enum.flat_map(packages, fn {package, base_url, cache} ->
        package_dir = Path.join(deps, package)

        [_, version] =
          Regex.run(~r/@version\s+"([^"]+)"/, File.read!(Path.join(package_dir, "mix.exs")))

        {:hex, _, ^version, _, _, _, _, _} = Map.fetch!(lock, String.to_atom(package))
        manifests = Path.wildcard(Path.join(package_dir, "checksum*.exs"))
        if manifests == [], do: raise("missing shipped checksum manifest for #{package}")

        Enum.flat_map(manifests, fn manifest ->
          {checksums, _} = Code.eval_file(manifest)

          targets =
            Enum.filter(checksums, fn {file, _} ->
              Regex.match?(
                ~r/-x86_64-(?:unknown-)?linux-gnu(?:--\w+)?(?:\.so)?(?:-[\d.]+)?\.tar\.gz$/,
                file
              )
            end)

          if targets == [], do: raise("missing x86_64 Linux glibc archive in #{manifest}")

          Enum.map(targets, fn {file, checksum} ->
            unless Path.basename(file) == file and
                     (String.contains?(file, "-v#{version}-") or
                        String.ends_with?(file, "-#{version}.tar.gz")) and
                     Regex.match?(~r/^sha256:[0-9a-f]{64}$/, checksum) do
              raise "invalid archive version or SHA-256 in #{manifest}: #{file}"
            end

            {file, String.replace_prefix(checksum, "sha256:", ""),
             "#{base_url}#{version}/#{file}", cache}
          end)
        end)
      end)

    Enum.each(archives, fn {file, hash, url, cache} ->
      File.mkdir_p!(cache)
      destination = Path.join(cache, file)

      if File.exists?(destination) do
        verify!(destination, hash)
      else
        temporary = destination <> ".download"

        try do
          {output, status} =
            System.cmd(
              "curl",
              [
                "--fail",
                "--location",
                "--silent",
                "--show-error",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--connect-timeout",
                "30",
                "--max-time",
                "300",
                "--output",
                temporary,
                url
              ],
              stderr_to_stdout: true
            )

          if status != 0, do: raise("native archive download failed: #{file}: #{output}")
          verify!(temporary, hash)
          File.rename!(temporary, destination)
        after
          File.rm(temporary)
        end
      end

      IO.puts("Verified native archive: #{file}")
    end)
  end

  defp verify!(path, expected) do
    actual = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

    unless actual == expected,
      do: raise("native archive SHA-256 mismatch: #{Path.basename(path)}")
  end
end

Manifold.CI.PrefetchNIFs.run()
