# vMaNGOS launcher assets

The launcher's `vmangos` target expects reusable SQL/data assets to already exist inside the Proxmox containers.

Expected paths:

- Game container data pack: `/opt/spp-assets/vmangos/data/`
- Game container world dump: `/opt/spp-assets/vmangos/sql/world.sql` or `/opt/spp-assets/vmangos/sql/world.7z`
- Optional supplemental world SQL: `/opt/spp-assets/vmangos/sql/world/*.sql`
- Optional supplemental characters SQL: `/opt/spp-assets/vmangos/sql/characters/*.sql`
- Optional supplemental logon SQL: `/opt/spp-assets/vmangos/sql/logon/*.sql`

The launcher imports:

- `logon.sql`, `characters.sql`, and `logs.sql` from the built vMaNGOS source tree at `/opt/source/sql`
- the reusable world dump from `/opt/spp-assets/vmangos/sql`
- `dbc/maps/vmaps/mmaps` from `/opt/spp-assets/vmangos/data`

This keeps the vMaNGOS lane separate from the packaged CMaNGOS SQL under `sql/vanilla`.
