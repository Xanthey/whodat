-- boss_detection.lua
-- WhoDAT - Improved Boss Detection
-- Combines multiple methods to accurately identify boss kills vs elite trash
-- Wrath 3.3.5a compatible

-- MULTI-SERVER SUPPORT:
-- Uses the shared server_translator.lua module for GUID parsing.
-- Correctly extracts creature IDs from Warmane and other servers.
-- See SERVER_TRANSLATOR_USAGE.md for details.

local ADDON_NAME = "WhoDAT"
local NS = _G[ADDON_NAME] or {}
_G[ADDON_NAME] = NS

-- ============================================================================
-- Boss Creature ID Database
-- ============================================================================
-- These are the actual NPC IDs (from GUID) of raid/dungeon bosses
-- Format: [creatureID] = "Boss Name"

local BOSS_CREATURE_IDS = {
  -- ========================================
  -- CLASSIC VANILLA DUNGEONS
  -- ========================================
  
  -- Ragefire Chasm
  [11517] = "Oggleflint",
  [11518] = "Jergosh the Invoker",
  [17830] = "Bazzalan",
  
  -- Wailing Caverns
  [3671] = "Lady Anacondra",
  [3673] = "Lord Cobrahn",
  [3674] = "Lord Pythas",
  [5775] = "Verdan the Everliving",
  [3654] = "Mutanus the Devourer",
  [3669] = "Lord Serpentis",
  [99999] = "Skum", -- placeholder ID
  [3653] = "Kresh",
  
  -- Deadmines
  [642] = "Sneed's Shredder",
  [643] = "Sneed",
  [644] = "Rhahk'Zor",
  [645] = "Edwin VanCleef",
  [647] = "Captain Greenskin",
  [1763] = "Gilnid",
  [599] = "Marisa du'Paige",
  [646] = "Mr. Smite",
  [3586] = "Defias Gunpowder",
  
  -- Shadowfang Keep
  [3886] = "Razorclaw the Butcher",
  [3887] = "Baron Silverlaine",
  [4278] = "Commander Springvale",
  [3914] = "Rethilgore",
  [4274] = "Fenrus the Devourer",
  [4275] = "Archmage Arugal",
  [4627] = "Arugal's Voidwalker",
  [3872] = "Deathsworn Captain",
  [3873] = "Tormented Officer",
  
  -- Blackfathom Deeps
  [4887] = "Ghamoo-ra",
  [4831] = "Lady Sarevess",
  [6243] = "Gelihast",
  [12902] = "Lorgus Jett",
  [4832] = "Twilight Lord Kelris",
  [4829] = "Aku'mai",
  [4830] = "Old Serra'kis",
  
  -- Stormwind Stockade
  [1716] = "Bazil Thredd",
  [1663] = "Dextren Ward",
  [1717] = "Hamhock",
  [1696] = "Targorr the Dread",
  [1666] = "Kam Deepfury",
  [1720] = "Bruegal Ironknuckle",
  
  -- Gnomeregan
  [6235] = "Electrocutioner 6000",
  [6229] = "Crowd Pummeler 9-60",
  [7361] = "Grubbis",
  [7800] = "Mekgineer Thermaplugg",
  [7079] = "Viscous Fallout",
  [6228] = "Dark Iron Ambassador",
  
  -- Razorfen Kraul
  [4424] = "Aggem Thorncurse",
  [4421] = "Charlga Razorflank",
  [4422] = "Overlord Ramtusk",
  [4425] = "Blind Hunter",
  [6168] = "Roogug",
  [4420] = "Overlord Ramtusk",
  
  -- Scarlet Monastery - Graveyard
  [3983] = "Interrogator Vishas",
  [3975] = "Herod", -- ARMORY WING BOSS
  [3974] = "Houndmaster Loksey",
  [4543] = "Bloodmage Thalnos",
  
  -- Scarlet Monastery - Library  
  [3976] = "Scarlet Commander Mograine",
  [3977] = "High Inquisitor Whitemane",
  
  -- Scarlet Monastery - Cathedral
  [3977] = "High Inquisitor Whitemane",
  [3976] = "Scarlet Commander Mograine",
  
  -- Razorfen Downs
  [7355] = "Tuten'kash",
  [7356] = "Plaguemaw the Rotting",
  [7357] = "Mordresh Fire Eye",
  [7358] = "Amnennar the Coldbringer",
  [8567] = "Glutton",
  
  -- Uldaman
  [6906] = "Baelog",
  [6907] = "Eric \"The Swift\"",
  [6908] = "Olaf",
  [4854] = "Grimlok",
  [6910] = "Revelosh",
  [7228] = "Ironaya",
  [7023] = "Obsidian Sentinel",
  [7206] = "Ancient Stone Keeper",
  [2748] = "Archaedas",
  
  -- Zul'Farrak
  [7271] = "Witch Doctor Zum'rah",
  [7272] = "Gahz'rilla",
  [7273] = "Antu'sul",
  [7797] = "Ruuzlu",
  [7275] = "Shadowpriest Sezz'ziz",
  [7274] = "Sandfury Executioner",
  [7796] = "Nekrum Gutchewer",
  [8127] = "Antu'sul",
  [7267] = "Chief Ukorz Sandscalp",
  
  -- Maraudon
  [13282] = "Noxxion",
  [12203] = "Landslide",
  [13601] = "Tinkerer Gizlock",
  [12225] = "Celebras the Cursed",
  [13596] = "Rotgrip",
  [12236] = "Lord Vyletongue",
  [13738] = "Meshlok the Harvester",
  [12258] = "Razorlash",
  [13280] = "Hydrospawn",
  [12259] = "Princess Theradras",
  
  -- Sunken Temple
  [5710] = "Jammal'an the Prophet",
  [5709] = "Shade of Eranikus",
  [5711] = "Ogom the Wretched",
  [5712] = "Zolo",
  [8384] = "Avatar of Hakkar",
  [5715] = "Hazzas",
  [5713] = "Gasher",
  [5714] = "Morphaz",
  [5716] = "Zul'Lor",
  
  -- Blackrock Depths
  [9018] = "High Interrogator Gerstahn",
  [9016] = "Bael'Gar",
  [9017] = "Lord Incendius",
  [9041] = "Warder Stilgiss",
  [9025] = "Lord Roccor",
  [9028] = "Grizzle",
  [9029] = "Eviscerator",
  [9031] = "Anub'shiah",
  [9030] = "Ok'thor the Breaker",
  [9032] = "Hedrum the Creeper",
  [9033] = "General Angerforge",
  [9034] = "Hate'rel",
  [9035] = "Anger'rel",
  [9036] = "Vile'rel",
  [9037] = "Gloom'rel",
  [9038] = "Seeth'rel",
  [9039] = "Doom'rel",
  [9040] = "Dope'rel",
  [9056] = "Fineous Darkvire",
  [9543] = "Ribbly Screwspigot",
  [9499] = "Plugger Spazzring",
  [9537] = "Hurley Blackbreath",
  [10096] = "High Justice Grimstone",
  [9938] = "Magmus",
  [9019] = "Emperor Dagran Thaurissan",
  [8983] = "Golem Lord Argelmach",
  [9502] = "Phalanx",
  [10220] = "Halycon",
  
  -- Lower Blackrock Spire
  [9196] = "Highlord Omokk",
  [9236] = "Shadow Hunter Vosh'gajin",
  [9237] = "War Master Voone",
  [10220] = "Halycon",
  [10268] = "Gizrul the Slavener",
  [9596] = "Bannok Grimaxe",
  [10318] = "Mor Grayhoof",
  [10596] = "Mother Smolderweb",
  [10584] = "Urok Doomhowl",
  [10899] = "Goraluk Anvilcrack",
  [9816] = "Pyroguard Emberseer",
  [16080] = "Mor Grayhoof",
  [10429] = "Warchief Rend Blackhand",
  [10339] = "Gyth",
  [10363] = "General Drakkisath",
  
  -- Upper Blackrock Spire (10-man raid)
  [10429] = "Warchief Rend Blackhand",
  [10339] = "Gyth",
  [10363] = "General Drakkisath",
  
  -- Dire Maul East
  [11490] = "Zevrim Thornhoof",
  [11492] = "Alzzin the Wildshaper",
  [11496] = "Immol'thar",
  [11486] = "Prince Tortheldrin",
  [13280] = "Hydrospawn",
  [14327] = "Lethtendris",
  
  -- Dire Maul West
  [11497] = "The Razza",
  [11498] = "Skarr the Unbreakable",
  [11501] = "King Gordok",
  [11492] = "Alzzin the Wildshaper",
  [14326] = "Guard Mol'dar",
  [14322] = "Stomper Kreeg",
  [14321] = "Guard Fengus",
  [14325] = "Captain Kromcrush",
  [14324] = "Cho'Rush the Observer",
  
  -- Dire Maul North
  [11488] = "Illyanna Ravenoak",
  [11487] = "Magister Kalendris",
  [11496] = "Immol'thar",
  [11486] = "Prince Tortheldrin",
  [14326] = "Guard Mol'dar",
  [14322] = "Stomper Kreeg",
  [14321] = "Guard Fengus",
  [14325] = "Captain Kromcrush",
  
  -- Scholomance
  [10506] = "Kirtonos the Herald",
  [11261] = "Doctor Theolen Krastinov",
  [10503] = "Jandice Barov",
  [11622] = "Rattlegore",
  [10433] = "Marduk Blackpool",
  [10432] = "Vectus",
  [10508] = "Ras Frostwhisper",
  [11981] = "Flamescale",
  [14539] = "Darkmaster Gandling",
  [10511] = "Jandice Barov",
  [16118] = "Kormok",
  [10516] = "The Unforgiven",
  [11258] = "Malicia",
  
  -- Stratholme
  [10558] = "Hearthsinger Forresten",
  [10516] = "The Unforgiven",
  [11032] = "Malor the Zealous",
  [10808] = "Timmy the Cruel",
  [11120] = "Crimson Hammersmith",
  [10516] = "The Unforgiven",
  [10997] = "Cannon Master Willey",
  [10811] = "Archivist Galford",
  [11143] = "Postmaster Malown",
  [11058] = "Fras Siabi",
  [10393] = "Skul",
  [10516] = "The Unforgiven",
  [10809] = "Stonespine",
  [10437] = "Nerub'enkan",
  [10438] = "Maleki the Pallid",
  [10435] = "Magistrate Barthilas",
  [10439] = "Ramstein the Gorger",
  [10440] = "Baron Rivendare",
  [45412] = "Lord Aurius Rivendare",
  
  -- ========================================
  -- CLASSIC VANILLA RAIDS
  -- ========================================
  
  -- Molten Core (40-man)
  [11502] = "Ragnaros",
  [12118] = "Lucifron",
  [11981] = "Flamescale",
  [12259] = "Gehennas",
  [12057] = "Garr",
  [12056] = "Baron Geddon",
  [11988] = "Golemagg the Incinerator",
  [12098] = "Sulfuron Harbinger",
  [12018] = "Majordomo Executus",
  [12264] = "Shazzrah",
  
  -- Blackwing Lair (40-man)
  [12435] = "Razorgore the Untamed",
  [13020] = "Vaelastrasz the Corrupt",
  [12017] = "Broodlord Lashlayer",
  [11983] = "Firemaw",
  [14020] = "Chromaggus",
  [11981] = "Flamegor",
  [14601] = "Ebonroc",
  [11583] = "Nefarian",
  
  -- Ahn'Qiraj 20 (AQ20)
  [15348] = "Kurinnaxx",
  [15341] = "General Rajaxx",
  [15340] = "Moam",
  [15370] = "Buru the Gorger",
  [15369] = "Ayamiss the Hunter",
  [15339] = "Ossirian the Unscarred",
  
  -- Ahn'Qiraj 40 (AQ40)
  [15263] = "The Prophet Skeram",
  [15510] = "Fankriss the Unyielding",
  [15509] = "Princess Huhuran",
  [15275] = "Emperor Vek'lor",
  [15276] = "Emperor Vek'nilash",
  [15517] = "Ouro",
  [15727] = "C'Thun",
  [15511] = "Lord Kri",
  [15543] = "Princess Yauj",
  [15544] = "Vem",
  [15516] = "Battleguard Sartura",
  
  -- Zul'Gurub (20-man)
  [14507] = "High Priest Venoxis",
  [14517] = "High Priestess Jeklik",
  [14510] = "High Priestess Mar'li",
  [14509] = "High Priest Thekal",
  [11382] = "Bloodlord Mandokir",
  [15114] = "Gahz'ranka",
  [14834] = "Hakkar",
  [15083] = "Hazza'rah",
  [15084] = "Renataki",
  [15085] = "Wushoolay",
  [15082] = "Gri'lek",
  [14515] = "High Priestess Arlokk",
  [14990] = "Ohgan",
  
  -- Ruins of Ahn'Qiraj (AQ20)
  -- (duplicates removed, listed above)
  
  -- Temple of Ahn'Qiraj (AQ40)
  -- (duplicates removed, listed above)
  
  -- World Bosses (Vanilla)
  [6109] = "Azuregos",
  [14889] = "Emeriss",
  [14888] = "Ysondre",
  [14890] = "Taerar",
  [14887] = "Lethon",
  [12397] = "Lord Kazzak",
  
  -- ========================================
  -- BURNING CRUSADE DUNGEONS
  -- ========================================
  
  -- Hellfire Ramparts
  [17306] = "Watchkeeper Gargolmar",
  [17308] = "Omor the Unscarred",
  [17537] = "Vazruden the Herald",
  [17307] = "Nazan",
  
  -- Blood Furnace
  [17380] = "Broggok",
  [17377] = "Keli'dan the Breaker",
  [17381] = "The Maker",
  
  -- Slave Pens
  [17941] = "Mennu the Betrayer",
  [17991] = "Rokmar the Crackler",
  [17942] = "Quagmirran",
  
  -- Underbog
  [17770] = "Hungarfen",
  [17827] = "Ghaz'an",
  [18105] = "Swamplord Musel'ek",
  [17826] = "The Black Stalker",
  
  -- Mana-Tombs
  [18341] = "Pandemonius",
  [18343] = "Tavarok",
  [19221] = "Nexus-Prince Shaffar",
  [18344] = "Yor",
  
  -- Auchenai Crypts
  [18371] = "Shirrak the Dead Watcher",
  [18373] = "Exarch Maladaar",
  
  -- Sethekk Halls
  [18473] = "Talon King Ikiss",
  [18667] = "Darkweaver Syth",
  [23035] = "Anzu",
  
  -- Shadow Labyrinth
  [18731] = "Ambassador Hellmaw",
  [18732] = "Grandmaster Vorpil",
  [18708] = "Murmur",
  [18733] = "Blackheart the Inciter",
  
  -- Old Hillsbrad Foothills (CoT)
  [17848] = "Lieutenant Drake",
  [17862] = "Captain Skarloc",
  [18096] = "Epoch Hunter",
  [17879] = "Thrall",
  
  -- Black Morass (CoT)
  [17879] = "Chrono Lord Deja",
  [17880] = "Temporus",
  [17881] = "Aeonus",
  
  -- Mechanar
  [19218] = "Gatewatcher Gyro-Kill",
  [19219] = "Gatewatcher Iron-Hand",
  [19221] = "Mechano-Lord Capacitus",
  [19710] = "Nethermancer Sepethrea",
  [19220] = "Pathaleon the Calculator",
  
  -- Botanica
  [17976] = "Commander Sarannis",
  [17975] = "High Botanist Freywinn",
  [17978] = "Thorngrin the Tender",
  [17977] = "Warp Splinter",
  [17980] = "Laj",
  
  -- Arcatraz
  [20870] = "Zereketh the Unbound",
  [20866] = "Soul-Trader Essences",
  [20885] = "Dalliah the Doomsayer",
  [20886] = "Wrath-Scryer Soccothrates",
  [20912] = "Harbinger Skyriss",
  
  -- Shattered Halls
  [16807] = "Grand Warlock Nethekurse",
  [16809] = "Warbringer O'mrogg",
  [17465] = "Warchief Kargath Bladefist",
  [20923] = "Blood Guard Porung",
  
  -- Magisters' Terrace
  [24723] = "Selin Fireheart",
  [24744] = "Vexallus",
  [24560] = "Priestess Delrissa",
  [24664] = "Kael'thas Sunstrider",
  
  -- ========================================
  -- BURNING CRUSADE RAIDS
  -- ========================================
  
  -- Karazhan
  [15550] = "Attumen the Huntsman",
  [16151] = "Midnight",
  [15687] = "Moroes",
  [15688] = "Maiden of Virtue",
  [16457] = "Romulo",
  [17534] = "Julianne",
  [15689] = "The Curator",
  [15691] = "The Big Bad Wolf",
  [17535] = "Dorothee",
  [17546] = "Roar",
  [17547] = "Tinhead",
  [17543] = "Strawman",
  [18168] = "The Crone",
  [15690] = "Terestian Illhoof",
  [15692] = "Shade of Aran",
  [15693] = "Prince Malchezaar",
  [16524] = "Netherspite",
  [17225] = "Nightbane",
  
  -- Gruul's Lair
  [18831] = "High King Maulgar",
  [18832] = "Krosh Firehand",
  [18834] = "Olm the Summoner",
  [18835] = "Kiggler the Crazed",
  [18836] = "Blindeye the Seer",
  [19044] = "Gruul the Dragonkiller",
  
  -- Magtheridon's Lair
  [17257] = "Magtheridon",
  
  -- Serpentshrine Cavern
  [21212] = "Lady Vashj",
  [21213] = "Morogrim Tidewalker",
  [21214] = "Fathom-Lord Karathress",
  [21215] = "The Lurker Below",
  [21217] = "The Tidewalker",
  [21216] = "Hydross the Unstable",
  [21217] = "Leotheras the Blind",
  
  -- Tempest Keep: The Eye
  [19514] = "Al'ar",
  [19516] = "Void Reaver",
  [18805] = "High Astromancer Solarian",
  [19622] = "Kael'thas Sunstrider",
  
  -- Mount Hyjal (CoT)
  [17767] = "Rage Winterchill",
  [17808] = "Anetheron",
  [17888] = "Kaz'rogal",
  [17842] = "Azgalor",
  [17968] = "Archimonde",
  
  -- Black Temple
  [22887] = "High Warlord Naj'entus",
  [22898] = "Supremus",
  [22841] = "Shade of Akama",
  [22871] = "Teron Gorefiend",
  [22948] = "Gurtogg Bloodboil",
  [22949] = "Reliquary of Souls",
  [22950] = "Mother Shahraz",
  [22951] = "Illidari Council",
  [23089] = "Illidan Stormrage",
  [22917] = "Illidan Stormrage",
  
  -- Sunwell Plateau
  [24882] = "Kalecgos",
  [24850] = "Sathrovarr the Corruptor",
  [24892] = "Brutallus",
  [25038] = "Felmyst",
  [25166] = "Grand Warlock Alythess",
  [25165] = "Lady Sacrolash",
  [25741] = "M'uru",
  [25315] = "Kil'jaeden",
  [25840] = "Entropius",
  
  -- Zul'Aman
  [23574] = "Akil'zon",
  [23576] = "Nalorakk",
  [23578] = "Jan'alai",
  [23577] = "Halazzi",
  [24239] = "Hex Lord Malacrass",
  [23863] = "Zul'jin",
  
  -- World Bosses (TBC)
  [17711] = "Doomwalker",
  [18728] = "Doom Lord Kazzak",
  
  -- ========================================
  -- Naxxramas (25/40)
  -- ========================================
  [15928] = "Thaddius",
  [15929] = "Stalagg",
  [15930] = "Feugen",
  [15931] = "Grobbulus",
  [15932] = "Gluth",
  [15936] = "Heigan the Unclean",
  [15952] = "Maexxna",
  [15953] = "Grand Widow Faerlina",
  [15954] = "Noth the Plaguebringer",
  [15956] = "Anub'Rekhan",
  [16011] = "Loatheb",
  [16028] = "Patchwerk",
  [16060] = "Gothik the Harvester",
  [16061] = "Instructor Razuvious",
  [16062] = "Highlord Mograine",
  [16063] = "Sir Zeliek",
  [16064] = "Thane Korth'azz",
  [16065] = "Lady Blaumeux",
  [15989] = "Sapphiron",
  [15990] = "Kel'Thuzad",
  
  -- ========================================
  -- Ulduar
  -- ========================================
  [33113] = "Flame Leviathan",
  [33118] = "Ignis the Furnace Master",
  [33186] = "Razorscale",
  [33293] = "XT-002 Deconstructor",
  [32857] = "Stormcaller Brundir",
  [32867] = "Steelbreaker",
  [32927] = "Runemaster Molgeim",
  [32845] = "Hodir",
  [32846] = "Thorim",
  [32865] = "Freya",
  [33271] = "General Vezax",
  [33288] = "Yogg-Saron",
  [32930] = "Kologarn",
  [32906] = "Freya",
  [33515] = "Auriaya",
  [32915] = "Elder Brightleaf",
  [32913] = "Elder Ironbranch",
  [32914] = "Elder Stonebark",
  [33350] = "Mimiron",
  [32934] = "Left Arm",
  [32933] = "Right Arm",
  [33670] = "Aerial Command Unit",
  [34014] = "VX-001",
  [34106] = "Leviathan Mk II",
  [33651] = "VX-001",
  [33432] = "Leviathan Mk II",
  [32930] = "Kologarn",
  [32934] = "Left Arm",
  [32933] = "Right Arm",
  [34175] = "Assembly of Iron",
  [32871] = "Algalon the Observer",
  
  -- ========================================
  -- Trial of the Crusader
  -- ========================================
  [34497] = "Fjola Lightbane",
  [34496] = "Eydis Darkbane",
  [35013] = "Lord Jaraxxus",
  [34564] = "Anub'arak",
  [34780] = "Gormok the Impaler",
  [34797] = "Acidmaw",
  [34799] = "Dreadscale",
  [34796] = "Icehowl",
  
  -- ========================================
  -- Icecrown Citadel
  -- ========================================
  [36612] = "Lord Marrowgar",
  [36855] = "Lady Deathwhisper",
  [37813] = "Deathbringer Saurfang",
  [36626] = "Festergut",
  [36627] = "Rotface",
  [36678] = "Professor Putricide",
  [37972] = "Prince Keleseth",
  [37973] = "Prince Taldaram",
  [37970] = "Prince Valanar",
  [37955] = "Blood-Queen Lana'thel",
  [36789] = "Valithria Dreamwalker",
  [36853] = "Sindragosa",
  [36597] = "The Lich King",
  [37217] = "Precious",
  [37025] = "Stinki",
  
  -- ========================================
  -- Ruby Sanctum
  -- ========================================
  [39863] = "Halion",
  
  -- ========================================
  -- Obsidian Sanctum
  -- ========================================
  [28860] = "Sartharion",
  [30451] = "Tenebron",
  [30452] = "Shadron",
  [30449] = "Vesperon",
  
  -- ========================================
  -- Eye of Eternity
  -- ========================================
  [28859] = "Malygos",
  
  -- ========================================
  -- Vault of Archavon
  -- ========================================
  [31125] = "Archavon the Stone Watcher",
  [33993] = "Emalon the Storm Watcher",
  [35013] = "Koralon the Flame Watcher",
  [38433] = "Toravon the Ice Watcher",
  
  -- ========================================
  -- Onyxia's Lair
  -- ========================================
  [10184] = "Onyxia",
  
  -- ========================================
  -- Heroic Dungeon Bosses (5-man)
  -- ========================================
  
  -- The Nexus
  [26798] = "Commander Stoutbeard",
  [26731] = "Grand Magus Telestra",
  [26763] = "Anomalus",
  [26794] = "Ormorok the Tree-Shaper",
  [26723] = "Keristrasza",
  
  -- Azjol-Nerub
  [28684] = "Krik'thir the Gatewatcher",
  [28921] = "Hadronox",
  [29120] = "Anub'arak",
  
  -- Ahn'kahet
  [29309] = "Elder Nadox",
  [29308] = "Prince Taldaram",
  [29310] = "Jedoga Shadowseeker",
  [30258] = "Amanitar",
  [29311] = "Herald Volazj",
  
  -- Drak'Tharon Keep
  [26630] = "Trollgore",
  [26631] = "Novos the Summoner",
  [26632] = "King Dred",
  [26633] = "The Prophet Tharon'ja",
  
  -- Violet Hold
  [29266] = "Erekem",
  [29315] = "Ichoron",
  [29313] = "Lavanthor",
  [29312] = "Moragg",
  [29316] = "Xevozz",
  [29314] = "Zuramat the Obliterator",
  [31134] = "Cyanigosa",
  
  -- Gundrak
  [29304] = "Slad'ran",
  [29305] = "Moorabi",
  [29306] = "Drakkari Colossus",
  [29307] = "Gal'darah",
  [29932] = "Eck the Ferocious",
  
  -- Halls of Stone
  [27977] = "Krystallus",
  [27975] = "Maiden of Grief",
  [27978] = "Sjonnir the Ironshaper",
  [28234] = "Tribunal of Ages",
  
  -- Halls of Lightning
  [28546] = "General Bjarngrim",
  [28587] = "Volkhan",
  [28923] = "Ionar",
  [28584] = "Loken",
  
  -- Oculus
  [27654] = "Drakos the Interrogator",
  [27447] = "Varos Cloudstrider",
  [27655] = "Mage-Lord Urom",
  [27656] = "Ley-Guardian Eregos",
  
  -- Utgarde Keep
  [23953] = "Prince Keleseth",
  [24201] = "Skarvald the Constructor",
  [23954] = "Ingvar the Plunderer",
  [24200] = "Dalronn the Controller",
  
  -- Utgarde Pinnacle
  [26668] = "Svala Sorrowgrave",
  [26687] = "Gortok Palehoof",
  [26693] = "Skadi the Ruthless",
  [26861] = "King Ymiron",
  
  -- Culling of Stratholme
  [26529] = "Meathook",
  [26530] = "Salramm the Fleshcrafter",
  [26532] = "Chrono-Lord Epoch",
  [32273] = "Infinite Corruptor",
  [26533] = "Mal'Ganis",
  
  -- Trial of the Champion
  [35617] = "Grand Champions",
  [34928] = "Argent Confessor Paletress",
  [35119] = "Eadric the Pure",
  [35451] = "The Black Knight",
  
  -- Pit of Saron
  [36494] = "Forgemaster Garfrost",
  [36477] = "Ick",
  [36658] = "Scourgelord Tyrannus",
  [36476] = "Krick",
  
  -- Forge of Souls
  [36497] = "Bronjahm",
  [36502] = "Devourer of Souls",
  
  -- Halls of Reflection
  [38112] = "Falric",
  [38113] = "Marwyn",
  [37226] = "The Lich King",
}

-- ============================================================================
-- Enhanced Boss Detection
-- ============================================================================

-- Track confirmed boss encounters via events
local confirmedBossEncounters = {}

-- WARMANE-COMPATIBLE

local function GetCreatureIDFromGUID(guid)
  -- Use shared server translator for GUID parsing
  -- This correctly handles Warmane, retail, and other server formats
  return NS.ServerTranslator:ExtractCreatureID(guid)
end

-- Check if a creature ID is a known boss
local function IsKnownBoss(creatureID)
  return creatureID and BOSS_CREATURE_IDS[creatureID] ~= nil
end

-- Check if unit is a boss using multiple methods
function NS.IsBoss(unitID, guid, name)
  -- Method 1: Check if we've seen an ENCOUNTER_END event for this name recently
  if name and confirmedBossEncounters[name] then
    local timeSince = time() - confirmedBossEncounters[name]
    if timeSince < 300 then  -- Within last 5 minutes
      return true, "encounter_event"
    end
  end
  
  -- Method 2: Check GUID against known boss creature IDs
  local creatureID = GetCreatureIDFromGUID(guid)
  if IsKnownBoss(creatureID) then
    return true, "creature_id_whitelist"
  end
  
  -- Method 3: WorldBoss classification (always a boss)
  if unitID and UnitExists(unitID) then
    local classification = UnitClassification(unitID)
    if classification == "worldboss" then
      return true, "worldboss_classification"
    end
  end
  
  -- Method 4: Elite in a raid instance (lower confidence)
  if unitID and UnitExists(unitID) then
    local classification = UnitClassification(unitID)
    if classification == "elite" then
      local inInstance, instanceType = IsInInstance()
      if inInstance and instanceType == "raid" then
        -- This is an elite in a raid - likely a boss but could be trash
        -- Return true but with lower confidence
        return true, "elite_in_raid_instance"
      end
    end
  end
  
  -- Not a boss
  return false, "not_boss"
end

-- Update the GetCurrentTarget function to use new detection
function NS.GetEnhancedTargetInfo()
  if not UnitExists("target") then
    return nil
  end
  
  local name = UnitName("target")
  local guid = UnitGUID("target")
  local classification = UnitClassification("target")
  local isBoss, bossMethod = NS.IsBoss("target", guid, name)
  
  return {
    name = name,
    guid = guid,
    level = UnitLevel("target"),
    classification = classification,
    is_boss = isBoss,
    boss_detection_method = bossMethod,
    creature_id = GetCreatureIDFromGUID(guid),
  }
end

-- ============================================================================
-- Event Tracking
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("ENCOUNTER_END")
frame:RegisterEvent("BOSS_KILL")

frame:SetScript("OnEvent", function(self, event, ...)
  if event == "ENCOUNTER_END" then
    local encounterID, encounterName, difficultyID, raidSize, endStatus = ...
    
    -- endStatus: 1 = kill, 0 = wipe
    if endStatus == 1 then
      -- Mark this boss as confirmed
      confirmedBossEncounters[encounterName] = time()
      
      if NS.Log then
        NS.Log("INFO", "Boss encounter confirmed: %s (ID: %d)", 
          encounterName, encounterID)
      end
    end
    
  elseif event == "BOSS_KILL" then
    local encounterID, name = ...
    
    -- Mark this boss as confirmed
    confirmedBossEncounters[name] = time()
    
    if NS.Log then
      NS.Log("INFO", "Boss kill confirmed: %s (ID: %d)", 
        name, encounterID)
    end
  end
end)

-- Clean up old confirmed encounters (older than 1 hour)
local cleanupTimer = 0
frame:SetScript("OnUpdate", function(self, elapsed)
  cleanupTimer = cleanupTimer + elapsed
  
  if cleanupTimer >= 600 then  -- Every 10 minutes
    cleanupTimer = 0
    
    local now = time()
    for name, timestamp in pairs(confirmedBossEncounters) do
      if now - timestamp > 3600 then  -- 1 hour
        confirmedBossEncounters[name] = nil
      end
    end
  end
end)

-- ============================================================================
-- Public API
-- ============================================================================

-- Add a boss creature ID at runtime (for custom/private server bosses)
function NS.RegisterBossCreatureID(creatureID, bossName)
  BOSS_CREATURE_IDS[creatureID] = bossName
  
  if NS.Log then
    NS.Log("INFO", "Registered custom boss: %s (ID: %d)", bossName, creatureID)
  end
end

-- Get boss name from creature ID
function NS.GetBossNameFromCreatureID(creatureID)
  return BOSS_CREATURE_IDS[creatureID]
end

-- Check if a creature ID is registered as a boss
function NS.IsRegisteredBoss(creatureID)
  return IsKnownBoss(creatureID)
end

-- Get all registered boss IDs
function NS.GetRegisteredBossCount()
  local count = 0
  for _ in pairs(BOSS_CREATURE_IDS) do
    count = count + 1
  end
  return count
end

return NS