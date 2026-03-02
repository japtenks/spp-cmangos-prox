# SPP Proxmox Stax v0.1
 - Vanilla (1.12), The Burning Crusade (2.4.3) and WotLK (3.3.5) versions are supported
 - 
 - Services are split per function
 - MariaDB
 - Webhost
 - Login (one account all realms)
 - Worlds {Vanilla, TBC, WOTLK}
 - 
 - 
# Installation
For use on machine with proxmox installed. 
Tested under 9.1
On the host machine run ./launcher.sh

# Starting server

# Shutting down

# Starting server after shutdown

# Bot Addon
 - You can find latest Mangosbot Addon for WoW in SPP_Server/Addons folder. Copy Mangosbot folder in WoW/Interface/AddOns/
- When you start the game make sure "Load out-of-date Addons" is enabled in Addons list.

# Settings
 - Before you start, you can edit the Settings in SPP_Classics_V2/SPP_Server/Settings/%expansion%/ folder

# _**aiplayerbot.conf**_:
  ## Find these settings:
  AiPlayerbot.MinRandomBots = 1000
  AiPlayerbot.MaxRandomBots = 1000
  AiPlayerbot.RandomBotMinLevel = 1
  AiPlayerbot.RandomBotMaxLevel = 60

 - By default bot number is 1000. If you experience lag after 30+ minutes of running the server, try lowering bot number.
 - **Important!:** if you change bot number later, you will need to do "6 - Bots Menu -> Reset Random Bots" for changes to take effect.

  AiPlayerbot.SyncQuestWithPlayer = 0
 - If you set this to 1, bots in group will automatically complete & get reward from quest (If they have it) when you complete it.
 - E.g. you take quest to loot 10 items. You have 4 bots in group, they also take it. You loot 10 items, go back and complete the quest. Bots will complete it automatically and get rewards. So you won't have to loot 40 more items. Bots will ignore looting quest items.

  AiPlayerbot.AutoLearnTrainerSpells = 0
  AiPlayerbot.AutoLearnQuestSpells = 0
 - With this set to 1 bots will learn new spells/quest spells on levelup.
 - You can leave other settings unchanged.
# _**mangosd.conf**_:
 - here you can change XP and other rates. Look for "SERVER RATES" and change them if you want.
