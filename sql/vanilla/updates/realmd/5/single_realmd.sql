DROP TABLE IF EXISTS `realmd_db_version`;

CREATE TABLE `realmd_db_version` (
  `required_s2474_01_realmd_joindate_datetime` bit(1) DEFAULT NULL,
  `required_z2820_01_realmd_joindate_datetime` bit(1) DEFAULT NULL,
  `required_14083_01_realmd_joindate_datetime` bit(1) DEFAULT NULL
) ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_general_ci
COMMENT='Single realmD server';

INSERT INTO `realmd_db_version`
(`required_s2474_01_realmd_joindate_datetime`,
 `required_z2820_01_realmd_joindate_datetime`,
 `required_14083_01_realmd_joindate_datetime`)
VALUES (NULL, NULL, NULL);