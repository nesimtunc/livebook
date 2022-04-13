defmodule Mix.Tasks.App.Run do
  @moduledoc false
  use Mix.Task

  @requirements ["compile"]

  def run([task]) do
    case :os.type() do
      {:unix, :darwin} ->
        name = Mix.Project.config()[:name]
        app_root = Path.join(Mix.Project.build_path(), name <> ".app")

        file([app_root, "Contents", "Info.plist"], """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleName</key>
          <string>#{name}</string>
        </dict>
        </plist>
        """)

        elixir_bin = "elixir" |> System.find_executable() |> Path.dirname()
        otp_bin = "erl" |> System.find_executable() |> Path.dirname()
        log_path = Path.join([File.cwd!(), "tmp", name <> ".log"])

        file([app_root, "Contents", "MacOS", name], [chmod: 0o755], """
        #!/bin/sh

        export PATH="#{elixir_bin}:#{otp_bin}:$PATH"
        export MIX_ENV=#{Mix.env()}
        export MIX_TARGET=#{Mix.target()}
        cd "#{File.cwd!()}"
        elixir --name app \
          -e 'Node.connect(:"runner@#{:net_adm.localhost()}")' \
          -S mix #{task} 2>&1 > #{log_path}
        """)

        {:ok, _} = Node.start(:runner, :longnames)
        :ok = :net_kernel.monitor_nodes(true)

        {_, 0} = System.cmd("open", [app_root])
        app_node = :"app@#{:net_adm.localhost()}"

        receive do
          {:nodeup, ^app_node} ->
            :ok
        end

        Task.start_link(fn ->
          System.cmd("tail", ["-f", log_path], into: IO.stream())
        end)

        receive do
          {:nodedown, ^app_node} ->
            :ok
        end
    end
  end

  defp file(path, options \\ [], content) do
    path = Path.join(path)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)

    if chmod = options[:chmod] do
      File.chmod!(path, chmod)
    end
  end
end
