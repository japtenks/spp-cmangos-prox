/* =======================================================
   BOT COMMANDS DATABASE
   ======================================================= */
DROP TABLE IF EXISTS `bot_command`;
CREATE TABLE `bot_command` (
  `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name` VARCHAR(100) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  `security` TINYINT(3) UNSIGNED NOT NULL DEFAULT '0',
  `category` VARCHAR(64) NULL DEFAULT NULL COLLATE 'utf8_general_ci',
  `subcategory` VARCHAR(64) NULL DEFAULT NULL COLLATE 'utf8_general_ci',
  `help` LONGTEXT NULL DEFAULT NULL COLLATE 'utf8_general_ci',
  PRIMARY KEY (`id`)
)
COMMENT='Bot and Playerbot Chat Commands'
COLLATE='utf8_general_ci'
ENGINE=MyISAM
ROW_FORMAT=DYNAMIC;

/* =======================================================
   SECTION 1 – SYSTEM BOT COMMANDS
   ======================================================= */
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('.ahbot item <item id>', 3, 'System Commands', 'AHBot', 'Check current ahbot configuration for a specific item ID.'),
('.ahbot item <item id> <item value> <chance> <min amount> <max amount>', 3, 'System Commands', 'AHBot', 'Override ahbot config with custom price, chance (1–100) and amount range.'),
('.ahbot item <item id> reset', 3, 'System Commands', 'AHBot', 'Reset ahbot configuration for a specific item.'),
('.bot add <bot name>', 0, 'System Commands', 'Bot Management', 'Add a bot to the game; must belong to your account or guild.'),
('.bot ammo <bot name>', 0, 'System Commands', 'Bot Management', 'Give relevant ammo to specified bot.'),
('.bot consumables <bot name>', 0, 'System Commands', 'Bot Management', 'Give consumables to the bot.'),
('.bot enchants <bot name>', 0, 'System Commands', 'Bot Management', 'Enchant bot gear appropriately for its class/spec.'),
('.bot food <bot name>', 0, 'System Commands', 'Bot Management', 'Give food and drink to the bot.'),
('.bot gear <bot name>', 0, 'System Commands', 'Bot Management', 'Randomize bot gear; max level based on RandomGearMaxLevel.'),
('.bot init <bot name>', 0, 'System Commands', 'Bot Management', 'Level bot to your level, randomize gear, learn spells, and give items.'),
('.bot learn <bot name>', 0, 'System Commands', 'Bot Management', 'Teach all spells to the bot for its level.'),
('.bot pet <bot name>', 0, 'System Commands', 'Bot Management', 'Initialize bot pet (hunter tame / warlock train).'),
('.bot potions <bot name>', 0, 'System Commands', 'Bot Management', 'Give potion reagents to the bot.'),
('.bot prepare <bot name>', 0, 'System Commands', 'Bot Management', 'Give ammo, food, potions, reagents, and consumables.'),
('.bot reagents <bot name>', 0, 'System Commands', 'Bot Management', 'Give reagents to the bot.'),
('.bot remove <bot name>', 0, 'System Commands', 'Bot Management', 'Remove bot from the world.'),
('.bot train <bot name>', 0, 'System Commands', 'Bot Management', 'Make bot learn all available class spells.'),
('.bot upgrade <bot name>', 0, 'System Commands', 'Bot Management', 'Upgrade bot gear to better quality.'),
('.rndbot diff', 1, 'System Commands', 'Server Tools', 'Show average and max difficulty (server load indicator).'),
('.rndbot reload', 3, 'System Commands', 'Server Tools', 'Reload all bot configuration live from aiplayerbot.conf.'),
('.rndbot stats', 1, 'System Commands', 'Server Tools', 'Display statistics about active bots.'),
('.rndbot teleport', 3, 'System Commands', 'Server Tools', 'Teleport all bots randomly based on level.');
/* =======================================================
   SECTION 2 – CHAT COMMANDS
   ======================================================= */

-- QUEST INTERACTION
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('accept [quest link]', 0, 'Chat Commands', 'Quest Interaction', 'Tell the bot to accept a specific quest from selected NPC.'),
('accept all', 0, 'Chat Commands', 'Quest Interaction', 'Tell the bot to accept all available quests.'),
('doquest [quest link/quest id]', 0, 'Chat Commands', 'Quest Interaction', 'Make bot focus on a chosen quest.'),
('drop <quest name>', 0, 'Chat Commands', 'Quest Interaction', 'Ask bot to drop a specific quest.'),
('drop all', 0, 'Chat Commands', 'Quest Interaction', 'Ask bot to abandon all quests.'),
('share [quest link]', 0, 'Chat Commands', 'Quest Interaction', 'Ask bot to share a quest.'),
('quests', 0, 'Chat Commands', 'Quest Interaction', 'Show bot’s quest progress.'),
('quests <co/in/all>', 0, 'Chat Commands', 'Quest Interaction', 'Filter quest list (completed/incomplete/all).');

-- COMBAT & ACTIONS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('attack', 0, 'Chat Commands', 'Combat', 'Tell bot to attack your current target.'),
('attack rti', 0, 'Chat Commands', 'Combat', 'Attack assigned raid target.'),
('flee', 0, 'Chat Commands', 'Combat', 'Bot flees and goes passive.'),
('pull', 0, 'Chat Commands', 'Combat', 'Tell bot to pull current target.'),
('pull rti', 0, 'Chat Commands', 'Combat', 'Pull assigned raid target.'),
('cast <spell name>', 0, 'Chat Commands', 'Combat', 'Cast the specified spell.'),
('summon', 3, 'Chat Commands', 'Combat', 'Force summon and revive bot.'),
('rti <raid icon>', 0, 'Chat Commands', 'Combat', 'Assign raid target for attack.'),
('rti cc <raid icon>', 0, 'Chat Commands', 'Combat', 'Assign raid target for CC.'),
('reset ai', 3, 'Chat Commands', 'Combat', 'Reset bot AI and reload defaults.');

-- MOVEMENT & BEHAVIOR
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('follow', 0, 'Chat Commands', 'Movement', 'Tell bot to follow you.'),
('follow target <name>', 0, 'Chat Commands', 'Movement', 'Follow specific player.'),
('guard', 0, 'Chat Commands', 'Movement', 'Guard current area.'),
('stay', 0, 'Chat Commands', 'Movement', 'Hold position.'),
('go npc <npc name>', 0, 'Chat Commands', 'Movement', 'Travel to a specific NPC.'),
('go zone <location name>', 0, 'Chat Commands', 'Movement', 'Travel to a location or zone.'),
('home', 0, 'Chat Commands', 'Movement', 'Set home at selected innkeeper.'),
('revive', 0, 'Chat Commands', 'Movement', 'Revive at nearest spirit healer.'),
('release', 0, 'Chat Commands', 'Movement', 'Release spirit when dead.'),
('rtsc save <position name>', 1, 'Chat Commands', 'Movement', 'Save named RTSC position.'),
('rtsc go <position name>', 1, 'Chat Commands', 'Movement', 'Go to saved RTSC position.'),
('rtsc unsave <position name>', 1, 'Chat Commands', 'Movement', 'Delete saved RTSC position.');

-- INVENTORY & ECONOMY
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('bank', 0, 'Chat Commands', 'Inventory', 'List items in bot bank.'),
('bank [item link]', 0, 'Chat Commands', 'Inventory', 'Deposit item to bank.'),
('bank -[item link]', 0, 'Chat Commands', 'Inventory', 'Withdraw item from bank.'),
('items', 0, 'Chat Commands', 'Inventory', 'List items in bags.'),
('items ah', 0, 'Chat Commands', 'Inventory', 'Show items bot plans to sell on AH.'),
('keep [item link]', 0, 'Chat Commands', 'Inventory', 'Mark item to keep.'),
('keep equip [item link]', 0, 'Chat Commands', 'Inventory', 'Keep item equipped.'),
('keep none [item link]', 0, 'Chat Commands', 'Inventory', 'Remove keep status.'),
('s [item link]', 0, 'Chat Commands', 'Inventory', 'Sell specified item.'),
('b [item link]', 0, 'Chat Commands', 'Inventory', 'Buy specified item.'),
('mail ?', 0, 'Chat Commands', 'Inventory', 'List pending mail.'),
('mail take', 0, 'Chat Commands', 'Inventory', 'Retrieve mail or items.'),
('sendmail [item link]', 0, 'Chat Commands', 'Inventory', 'Send item to player.'),
('repair', 0, 'Chat Commands', 'Inventory', 'Repair bot gear at vendor.');

-- GROUP & GUILD
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('join', 0, 'Chat Commands', 'Group and Guild', 'Join player group.'),
('leave', 0, 'Chat Commands', 'Group and Guild', 'Leave current group or raid.'),
('give leader', 0, 'Chat Commands', 'Group and Guild', 'Give leader privileges to player.'),
('guild leave', 0, 'Chat Commands', 'Group and Guild', 'Leave current guild.'),
('lfg', 0, 'Chat Commands', 'Group and Guild', 'Auto-find group based on role.');

-- TRAINING & TALENTS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('trainer', 0, 'Chat Commands', 'Training', 'List trainable skills.'),
('trainer learn', 0, 'Chat Commands', 'Training', 'Learn all trainable skills.'),
('talents', 0, 'Chat Commands', 'Training', 'Report current talent build.'),
('talents auto', 0, 'Chat Commands', 'Training', 'Auto-choose build.'),
('talents list', 0, 'Chat Commands', 'Training', 'List all available builds.'),
('talents <build name>', 0, 'Chat Commands', 'Training', 'Switch to a specific build.');

-- UTILITY & INFO
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('help', 0, 'Chat Commands', 'Utility', 'Show bot help menu.'),
('who', 0, 'Chat Commands', 'Utility', 'Get bot info: spec, item level, etc.'),
('stats', 0, 'Chat Commands', 'Utility', 'Show bot stats: gold, xp, bags.'),
('skill', 0, 'Chat Commands', 'Utility', 'List all skill levels.'),
('skill [name]', 0, 'Chat Commands', 'Utility', 'Show specific skill.'),
('skill unlearn [name]', 0, 'Chat Commands', 'Utility', 'Unlearn profession.'),
('faction', 0, 'Chat Commands', 'Utility', 'List factions and reputation.'),
('faction [name]', 0, 'Chat Commands', 'Utility', 'Show specific faction rep.'),
('faction +atwar [name]', 0, 'Chat Commands', 'Utility', 'Flag faction at war.'),
('faction -atwar [name]', 0, 'Chat Commands', 'Utility', 'Remove war flag.'),
('outfit ?', 0, 'Chat Commands', 'Utility', 'List available outfits.'),
('outfit <name> equip', 0, 'Chat Commands', 'Utility', 'Equip outfit.'),
('outfit <name> reset', 0, 'Chat Commands', 'Utility', 'Reset outfit.'),
('outfit <name> update', 0, 'Chat Commands', 'Utility', 'Update outfit.'),
('emote <emote name>', 0, 'Chat Commands', 'Utility', 'Perform emote.');

-- GM LEVEL UTILITY
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('rndbot reload', 3, 'Chat Commands', 'GM Utility', 'Reload bot configuration live.'),
('rndbot teleport', 3, 'Chat Commands', 'GM Utility', 'Teleport all bots randomly.'),
('rndbot stats', 1, 'Chat Commands', 'GM Utility', 'Display bot statistics.'),
('rndbot diff', 1, 'Chat Commands', 'GM Utility', 'Show average and max difficulty.');

/* =======================================================
   SECTION 3 – CHAT COMMAND FILTERS
   ======================================================= */

-- ROLE FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@dps', 0, 'Chat Filters', 'Role', 'Selects all bots with DPS role.'),
('@nodps', 0, 'Chat Filters', 'Role', 'Selects bots that are not DPS.'),
('@tank', 0, 'Chat Filters', 'Role', 'Selects tank role bots.'),
('@notank', 0, 'Chat Filters', 'Role', 'Selects bots that are not tanks.'),
('@heal', 0, 'Chat Filters', 'Role', 'Selects healer role bots.');

-- CLASS FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@warrior', 0, 'Chat Filters', 'Class', 'Select all warrior bots.'),
('@paladin', 0, 'Chat Filters', 'Class', 'Select all paladin bots.'),
('@hunter', 0, 'Chat Filters', 'Class', 'Select all hunter bots.'),
('@rogue', 0, 'Chat Filters', 'Class', 'Select all rogue bots.'),
('@priest', 0, 'Chat Filters', 'Class', 'Select all priest bots.'),
('@shaman', 0, 'Chat Filters', 'Class', 'Select all shaman bots.'),
('@mage', 0, 'Chat Filters', 'Class', 'Select all mage bots.'),
('@warlock', 0, 'Chat Filters', 'Class', 'Select all warlock bots.'),
('@druid', 0, 'Chat Filters', 'Class', 'Select all druid bots.');

-- GROUP / RAID FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@group<number>', 0, 'Chat Filters', 'Group', 'Select bots in a specific group (e.g. @group1).'),
('@group1-3', 0, 'Chat Filters', 'Group', 'Select bots in a group range (e.g. @group1-3).'),
('@nogroup', 0, 'Chat Filters', 'Group', 'Select bots not in a group.'),
('@leader', 0, 'Chat Filters', 'Group', 'Select bots that are group leaders.'),
('@raid', 0, 'Chat Filters', 'Group', 'Select bots in a raid group.'),
('@noraid', 0, 'Chat Filters', 'Group', 'Select bots not in a raid group.'),
('@rleader', 0, 'Chat Filters', 'Group', 'Select bots that are raid leaders.');

-- LEVEL & GEAR FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@<level>', 0, 'Chat Filters', 'Level', 'Select bots of a specific level (e.g. @10 or @1-10).'),
('@tier1', 0, 'Chat Filters', 'Gear', 'Bots with average gear comparable to Tier 1.'),
('@tier2-3', 0, 'Chat Filters', 'Gear', 'Bots with average gear comparable to Tier 2–3.'),
('@tier4', 0, 'Chat Filters', 'Gear', 'Bots with average gear comparable to Tier 4.'),
('@tier5', 0, 'Chat Filters', 'Gear', 'Bots with average gear comparable to Tier 5.'),
('@tier6', 0, 'Chat Filters', 'Gear', 'Bots with average gear comparable to Tier 6.'),
('@tier7', 0, 'Chat Filters', 'Gear', 'Bots with average gear comparable to Tier 7.'),
('@tier8', 0, 'Chat Filters', 'Gear', 'Bots with average gear comparable to Tier 8.'),
('@tier9', 0, 'Chat Filters', 'Gear', 'Bots with average gear comparable to Tier 9.'),
('@tier10', 0, 'Chat Filters', 'Gear', 'Bots with average gear comparable to Tier 10.');

-- COMBAT STATE FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@ranged', 0, 'Chat Filters', 'Combat', 'Select bots that use ranged attacks.'),
('@melee', 0, 'Chat Filters', 'Combat', 'Select bots that use melee attacks.'),
('@dead', 0, 'Chat Filters', 'Combat', 'Select bots that are dead.'),
('@nodead', 0, 'Chat Filters', 'Combat', 'Select bots that are alive.');

-- GUILD FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@guild', 0, 'Chat Filters', 'Guild', 'Select all bots in a guild.'),
('@guild=<name>', 0, 'Chat Filters', 'Guild', 'Select bots in specific guild.'),
('@noguild', 0, 'Chat Filters', 'Guild', 'Select bots not in any guild.'),
('@gleader', 0, 'Chat Filters', 'Guild', 'Select bots that are guild leaders.'),
('@rank=<rank name>', 0, 'Chat Filters', 'Guild', 'Select bots with specific guild rank.');

-- STRATEGY & SPEC FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@<spec>', 0, 'Chat Filters', 'Strategy', 'Select bots of a specific spec (e.g. @fury).'),
('@<class>', 0, 'Chat Filters', 'Strategy', 'Select bots of a specific class (e.g. @mage).'),
('@nc=<strategy>', 0, 'Chat Filters', 'Strategy', 'Bots with <strategy> active in non-combat.'),
('@nonc=<strategy>', 0, 'Chat Filters', 'Strategy', 'Bots without <strategy> in non-combat.'),
('@co=<strategy>', 0, 'Chat Filters', 'Strategy', 'Bots with <strategy> in combat.'),
('@noco=<strategy>', 0, 'Chat Filters', 'Strategy', 'Bots without <strategy> in combat.'),
('@react=<strategy>', 0, 'Chat Filters', 'Strategy', 'Bots with <strategy> in reaction state.'),
('@noreact=<strategy>', 0, 'Chat Filters', 'Strategy', 'Bots without <strategy> in reaction state.'),
('@dead=<strategy>', 0, 'Chat Filters', 'Strategy', 'Bots with <strategy> while dead.'),
('@nodead=<strategy>', 0, 'Chat Filters', 'Strategy', 'Bots without <strategy> while dead.');

-- LOCATION / STATE FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@needrepair', 0, 'Chat Filters', 'State', 'Bots whose durability is below 20%.'),
('@outside', 0, 'Chat Filters', 'State', 'Bots currently outside of instances.'),
('@inside', 0, 'Chat Filters', 'State', 'Bots currently inside an instance.'),
('@azeroth', 0, 'Chat Filters', 'Location', 'Bots located in Azeroth overworld.'),
('@eastern kingdoms', 0, 'Chat Filters', 'Location', 'Bots located in Eastern Kingdoms.'),
('@dun morogh', 0, 'Chat Filters', 'Location', 'Bots located in Dun Morogh.');

-- ITEM USAGE FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@use=[itemlink]', 0, 'Chat Filters', 'Item Usage', 'Bots that have use for an item.'),
('@sell=[itemlink]', 0, 'Chat Filters', 'Item Usage', 'Bots that will sell or auction an item.'),
('@need=[itemlink]', 0, 'Chat Filters', 'Item Usage', 'Bots that will roll Need on an item.'),
('@greed=[itemlink]', 0, 'Chat Filters', 'Item Usage', 'Bots that will roll Greed on an item.');

-- TALENT / RANDOM FILTERS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('@frost', 0, 'Chat Filters', 'Talent Spec', 'Bots whose primary spec is Frost.'),
('@holy', 0, 'Chat Filters', 'Talent Spec', 'Bots whose primary spec is Holy.'),
('@random', 0, 'Chat Filters', 'Random', 'Selects 50% of bots at random.'),
('@random=25', 0, 'Chat Filters', 'Random', 'Selects 25% of bots at random.'),
('@fixedrandom', 0, 'Chat Filters', 'Random', 'Selects fixed 50% subset of bots.'),
('@fixedrandom=25', 0, 'Chat Filters', 'Random', 'Selects fixed 25% subset of bots.');
/* =======================================================
   SECTION 4 – STRATEGIES
   ======================================================= */

-- CORE STRATEGIES
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('aoe', 0, 'Strategies', 'Combat', 'Enable use of area-of-effect abilities.'),
('boost', 0, 'Strategies', 'Combat', 'Enable use of cooldowns and boost abilities.'),
('buff', 0, 'Strategies', 'Support', 'Enable buffing allies.'),
('cc', 0, 'Strategies', 'Combat', 'Enable crowd-control spells like Polymorph or Fear.'),
('cure', 0, 'Strategies', 'Support', 'Enable curing or cleansing debuffs from allies.'),
('heal', 0, 'Strategies', 'Support', 'Enable healing behavior for heal-capable classes.'),
('loot', 0, 'Strategies', 'Utility', 'Enable looting corpses and chests.'),
('offdps', 0, 'Strategies', 'Hybrid', 'Allow healers to DPS when idle.'),
('offheal', 0, 'Strategies', 'Hybrid', 'Allow DPS to perform supplemental healing.'),
('pull', 0, 'Strategies', 'Combat', 'Allow initiating pulls at range.'),
('pvp', 0, 'Strategies', 'Combat', 'Enable PvP combat.'),
('tank', 0, 'Strategies', 'Combat', 'Enable tanking behavior for tank classes.'),
('wait for attack', 0, 'Strategies', 'Combat', 'Bot waits before engaging in combat.');

-- STATE MANAGEMENT STRATEGIES
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('nc +<strategy>', 0, 'Strategies', 'Non-Combat', 'Add a non-combat strategy.'),
('nc -<strategy>', 0, 'Strategies', 'Non-Combat', 'Remove a non-combat strategy.'),
('nc ?', 0, 'Strategies', 'Non-Combat', 'List current non-combat strategies.'),
('co +<strategy>', 0, 'Strategies', 'Combat', 'Add a combat strategy.'),
('co -<strategy>', 0, 'Strategies', 'Combat', 'Remove a combat strategy.'),
('co ?', 0, 'Strategies', 'Combat', 'List current combat strategies.'),
('de +<strategy>', 0, 'Strategies', 'Dead', 'Add a dead-state strategy.'),
('de -<strategy>', 0, 'Strategies', 'Dead', 'Remove a dead-state strategy.'),
('de ?', 0, 'Strategies', 'Dead', 'List current dead-state strategies.'),
('react +<strategy>', 0, 'Strategies', 'Reaction', 'Add a reaction strategy.'),
('react -<strategy>', 0, 'Strategies', 'Reaction', 'Remove a reaction strategy.'),
('react ?', 0, 'Strategies', 'Reaction', 'List current reaction strategies.'),
('all +<strategy>', 0, 'Strategies', 'Global', 'Add a strategy to all states (combat, non-combat, dead, react).'),
('all -<strategy>', 0, 'Strategies', 'Global', 'Remove a strategy from all states.'),
('all ?', 0, 'Strategies', 'Global', 'List all currently active strategies.');
/* =======================================================
   SECTION 5 – MACROS & EXTENDED CHAT / RAID COMMANDS
   ======================================================= */

-- BEHAVIOR & CONTROL
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('stay', 0, 'Macros', 'Behavior', 'Bot holds current position until further orders.'),
('guard', 0, 'Macros', 'Behavior', 'Bot guards area and returns after combat.'),
('free', 0, 'Macros', 'Behavior', 'Bot moves independently during combat.'),
('follow', 0, 'Macros', 'Behavior', 'Bot follows the player or target.'),
('follow target <name>', 0, 'Macros', 'Behavior', 'Follow a specific target in group or raid.'),
('do follow', 0, 'Macros', 'Behavior', 'Force follow even during combat.'),
('+follow', 0, 'Macros', 'Behavior', 'Enable automatic following.'),
('-follow', 0, 'Macros', 'Behavior', 'Disable automatic following.'),
('+threat', 0, 'Macros', 'Behavior', 'Increase threat generation focus.'),
('home', 0, 'Macros', 'Behavior', 'Set home at selected innkeeper.'),
('+pvp', 0, 'Macros', 'Behavior', 'Enable PvP combat behavior.'),
('+wait for attack', 0, 'Macros', 'Behavior', 'Wait before starting combat with delay.'),
('nc +rpg', 0, 'Macros', 'Behavior', 'Enable roleplay behavior.'),
('nc -rpg', 0, 'Macros', 'Behavior', 'Disable roleplay behavior.'),
('+travel', 0, 'Macros', 'Behavior', 'Enable travel mode behavior.'),
('-travel', 0, 'Macros', 'Behavior', 'Disable travel mode behavior.');

-- COMBAT & STRATEGY CONTROL
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('co +boost', 0, 'Macros', 'Combat Setup', 'Enable use of cooldowns and boosts.'),
('co +pull', 0, 'Macros', 'Combat Setup', 'Enable ranged pulling behavior.'),
('co +tank', 0, 'Macros', 'Combat Setup', 'Enable tanking AI behavior.'),
('co +ranged', 0, 'Macros', 'Combat Setup', 'Switch to ranged combat.'),
('co -ranged', 0, 'Macros', 'Combat Setup', 'Switch to melee combat.'),
('+dps assist', 0, 'Macros', 'Combat Setup', 'Assist the main DPS target.'),
('+tank assist', 0, 'Macros', 'Combat Setup', 'Assist the tank’s target.'),
('cast <spellname>', 0, 'Macros', 'Combat Setup', 'Force-cast a spell by name.'),
('focus heal +<name>', 0, 'Macros', 'Combat Setup', 'Assign healing focus to target(s).'),
('focus heal none', 0, 'Macros', 'Combat Setup', 'Clear all healing focus targets.'),
('buff target +<name>', 0, 'Macros', 'Combat Setup', 'Buff specified target(s).'),
('buff target none', 0, 'Macros', 'Combat Setup', 'Clear buff targets.'),
('boost target +<name>', 0, 'Macros', 'Combat Setup', 'Assign boost targets (e.g. Innervate).'),
('boost target none', 0, 'Macros', 'Combat Setup', 'Clear boost targets.');

-- MOVEMENT & RTS CONTROL
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('rtsc save <position>', 0, 'Macros', 'Movement', 'Save custom RTSC movement position.'),
('rtsc go <position>', 0, 'Macros', 'Movement', 'Move to saved RTSC position.'),
('rtsc unsave <position>', 0, 'Macros', 'Movement', 'Delete saved RTSC position.'),
('rtsc select', 0, 'Macros', 'Movement', 'Select bot for manual RTSC control.'),
('rtsc cancel', 0, 'Macros', 'Movement', 'Cancel RTSC selection.'),
('go npc <name>', 0, 'Macros', 'Movement', 'Travel to specific NPC (requires free mode).'),
('go zone <location>', 0, 'Macros', 'Movement', 'Travel to specific zone (requires free mode).');

-- GROUP & RAID MACROS
INSERT INTO `bot_command` (name, security, category, subcategory, help) VALUES
('/p @tank @heal all -travel,+free,+follow', 0, 'Macros', 'Group', 'Form raid follow setup for tanks and healers.'),
('/p @group1 @tank co +tank,+aoe,+boost', 0, 'Macros', 'Group', 'Assign tank setup to group 1.'),
('/p @group2 @heal co +heal,+cleanse,+boost', 0, 'Macros', 'Group', 'Assign healer setup to group 2.'),
('/p @group3 @dps all +aoe,+boost,+threat', 0, 'Macros', 'Group', 'Assign DPS setup to group 3.'),
('/p @heal all +rpg,+buff,+heal', 0, 'Macros', 'Group', 'Enable roleplay and buffs for healers.'),
('/p all +follow', 0, 'Macros', 'Group', 'Make all bots follow.'),
('/p all -follow,+free', 0, 'Macros', 'Group', 'Release all bots from follow.'),
('/p all +stay', 0, 'Macros', 'Group', 'Hold all bots in position.'),
('/p all +guard', 0, 'Macros', 'Group', 'Set all bots to guard mode.'),
('/p @group1 co +tank,+threat,+boost,+pull', 0, 'Macros', 'Group', 'Tank setup for group 1.'),
('/p @group2 co +heal,+aoe,+cleanse', 0, 'Macros', 'Group', 'Healer setup for group 2.'),
('/p @group3 co +aoe,+boost,+melee', 0, 'Macros', 'Group', 'DPS setup for group 3.'),
('/p @heal focus heal +<Name>', 0, 'Macros', 'Group', 'Assign healing focus.'),
('/p @heal focus heal none', 0, 'Macros', 'Group', 'Clear all healing focus.'),
('/p @tank buff target +<Name>', 0, 'Macros', 'Group', 'Assign buff target for tanks.'),
('/p @tank buff target none', 0, 'Macros', 'Group', 'Remove tank buff targets.'),
('/p @tank boost target +<Name>', 0, 'Macros', 'Group', 'Assign boost targets for tanks.'),
('/p all +rpg,+travel', 0, 'Macros', 'Group', 'Enable travel and roleplay for all.'),
('/p all -rpg,-travel,+free', 0, 'Macros', 'Group', 'Disable travel and roleplay, enable free movement.'),
('/p @tank go npc <name>', 0, 'Macros', 'Group', 'Command tanks to move to an NPC.'),
('/p @tank go zone <location>', 0, 'Macros', 'Group', 'Command tanks to move to a zone.'),
('/p @group1 @heal home', 0, 'Macros', 'Group', 'Healers in group 1 set home.');

