if Mix.target() == :app do
  defmodule WxConstants do
    @moduledoc false

    defmacro wxID_ANY, do: -1
    defmacro wxID_OPEN, do: 5000
    defmacro wxID_EXIT, do: 5006
    defmacro wxID_OSX_HIDE, do: 5250
    defmacro wxBITMAP_TYPE_PNG, do: 15
  end

  defmodule LivebookApp do
    @moduledoc false

    use GenServer
    import WxConstants

    def start_link(arg) do
      GenServer.start_link(__MODULE__, arg, name: __MODULE__)
    end

    @impl true
    def init(_) do
      os = WxUtils.os()
      wx = :wx.new()

      if os == :macos do
        :wx.subscribe_events()
      end

      menu_items = [
        {"Open Browser", key: "ctrl+o", id: wxID_OPEN()},
        {"Quit", key: "ctrl+q", id: wxID_EXIT()}
      ]

      if os == :macos do
        :wxMenuBar.setAutoWindowMenu(false)

        menubar =
          WxUtils.menubar("Livebook", [
            {"File", menu_items}
          ])

        :ok = :wxMenuBar.connect(menubar, :command_menu_selected, skip: true)

        # TODO: use :wxMenuBar.macSetCommonMenuBar/1 when OTP 25 is out
        frame = :wxFrame.new(wx, -1, "", size: {0, 0})
        :wxFrame.show(frame)
        :wxFrame.setMenuBar(frame, menubar)
      end

      logo_path = "static/images/logo.png"
      icon = :wxIcon.new(logo_path, type: wxBITMAP_TYPE_PNG())
      taskbar = WxUtils.taskbar("Livebook", icon, menu_items)

      if os == :windows do
        :wxTaskBarIcon.connect(taskbar, :taskbar_left_down,
          callback: fn _, _ ->
            open_browser()
          end
        )
      end

      {:ok, nil}
    end

    @impl true
    def handle_info({:wx, wxID_EXIT(), _, _, _}, _state) do
      System.stop(0)
    end

    @impl true
    def handle_info({:wx, wxID_OPEN(), _, _, _}, state) do
      open_browser()
      {:noreply, state}
    end

    @impl true
    def handle_info(event, state) do
      IO.inspect(event)
      {:noreply, state}
    end

    defp open_browser do
      url = LivebookWeb.Endpoint.access_url()
      Livebook.Utils.browser_open(url)
    end
  end

  defmodule WxUtils do
    import WxConstants

    def os do
      case :os.type() do
        {:unix, :darwin} -> :macos
        {:win32, _} -> :windows
      end
    end

    def taskbar(title, icon, menu_items) do
      pid = self()
      options = if os() == :macos, do: [iconType: 1], else: []

      # skip keyboard shortcuts
      menu_items =
        for item <- menu_items do
          {title, options} = item
          options = Keyword.delete(options, :key)
          {title, options}
        end

      taskbar =
        :wxTaskBarIcon.new(
          [
            createPopupMenu: fn ->
              menu = menu(menu_items)

              # For some reason, on macOS the menu event must be handled in another process
              # but on Windows it must be either the same process OR we use the callback.
              case WxUtils.os() do
                :macos ->
                  env = :wx.get_env()

                  Task.start_link(fn ->
                    :wx.set_env(env)
                    :wxMenu.connect(menu, :command_menu_selected)

                    receive do
                      message ->
                        send(pid, message)
                    end
                  end)

                :windows ->
                  :ok =
                    :wxMenu.connect(menu, :command_menu_selected,
                      callback: fn wx, _ ->
                        send(pid, wx)
                      end
                    )
              end

              menu
            end
          ] ++ options
        )

      :wxTaskBarIcon.setIcon(taskbar, icon, tooltip: title)
      taskbar
    end

    def menu(items) do
      menu = :wxMenu.new()

      Enum.each(items, fn
        {title, options} ->
          id = Keyword.get(options, :id, wxID_ANY())

          title =
            case Keyword.fetch(options, :key) do
              {:ok, key} ->
                title <> "\t" <> key

              :error ->
                title
            end

          :wxMenu.append(menu, id, title)
      end)

      menu
    end

    def menubar(app_name, menus) do
      menubar = :wxMenuBar.new()

      if os() == :macos, do: fixup_macos_menubar(menubar, app_name)

      for {title, menu_items} <- menus do
        true = :wxMenuBar.append(menubar, menu(menu_items), title)
      end

      menubar
    end

    defp fixup_macos_menubar(menubar, app_name) do
      menu = :wxMenuBar.oSXGetAppleMenu(menubar)

      menu
      |> :wxMenu.findItem(wxID_OSX_HIDE())
      |> :wxMenuItem.setItemLabel("Hide #{app_name}\tCtrl+H")

      menu
      |> :wxMenu.findItem(wxID_EXIT())
      |> :wxMenuItem.setItemLabel("Quit #{app_name}\tCtrl+Q")
    end
  end
end
