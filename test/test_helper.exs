ExUnit.start()
ExUnit.configure(exclude: [:skip, :peer, :example])

:ok = JidoCluster.Test.Supervisor.ensure_started()
