File.rm_rf!(EventstoreSqlite.Cluster.db_dir())
ExUnit.configure(exclude: [:stress])
ExUnit.start()
Mneme.start()
