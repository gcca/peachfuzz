PRAGMA foreign_keys = ON;

BEGIN;

INSERT OR IGNORE INTO auth_user (username, password, email, is_active, created_at) VALUES
  ('jill.valentine', '$argon2d$v=19$m=65536,t=3,p=1$l4QNTCDg/j0FKLvbn6S1dg$U38bMJXE4Yq+Vq8F1SXtJ/GzZrEnlv+NF+bJJP0pZyA', 'jill.valentine@example.test', 1, 1783209600),
  ('chris.redfield', '$argon2d$v=19$m=65536,t=3,p=1$8EPWwDVhZ4DTWHxzZUNzWw$3sa74wSPFlLsL5Zx+8IfrVKDWeolPvZu1ITRAC4AxAg', 'chris.redfield@example.test', 1, 1783209600),
  ('barry.burton', '$argon2d$v=19$m=65536,t=3,p=1$gZm3jX7dqQuX4CKAuLnAmQ$eZ6nDCG0ccLWPue2jz6PAnTE9MHHwhzpGVCUCmeMRMU', 'barry.burton@example.test', 1, 1783209600),
  ('rebecca.chambers', '$argon2d$v=19$m=65536,t=3,p=1$RhdgruB9hDRnsqM4F2taMw$508oggxNqtYRou9BQJJp+zvhdCyejtrg0L0dbNI29Gs', 'rebecca.chambers@example.test', 1, 1783209600),
  ('albert.wesker', '$argon2d$v=19$m=65536,t=3,p=1$gz23aS2gS6NKo8Ga2yCPXQ$+Vz5dy/4KmIjTCaJJbjByABrkSydC0FqD/hstIITrPI', 'albert.wesker@example.test', 1, 1783209600),
  ('brad.vickers', '$argon2d$v=19$m=65536,t=3,p=1$tHA7QATMiw9WW1s7hJ4hhQ$InnrJdQP+kemighveJUoQ5ASvhVunvp/TepQqM9jkmc', 'brad.vickers@example.test', 1, 1783209600),
  ('richard.aiken', '$argon2d$v=19$m=65536,t=3,p=1$8OM6AeaBZ3GevbFDsmYedw$VeOKgcS9Tgmc9gWzdPS/JuqqD7AYKZYFrFMaDLi9uOQ', 'richard.aiken@example.test', 1, 1783209600),
  ('forest.speyer', '$argon2d$v=19$m=65536,t=3,p=1$A/udqccrh4ah7/DjaQK1dA$hoOP7MRKalz48KvG4Ar0u5JFAhwXODBFgAQZcpro2xA', 'forest.speyer@example.test', 1, 1783209600),
  ('kenneth.sullivan', '$argon2d$v=19$m=65536,t=3,p=1$IOsXkH6MhOkMaGuA/3X9Ug$IyZA8nwrRE4FG8dKi1yMoWJjjlf/2KXQ9ycwzPr6hOc', 'kenneth.sullivan@example.test', 1, 1783209600),
  ('joseph.frost', '$argon2d$v=19$m=65536,t=3,p=1$bzNYO+prIddHnYXnBBAFhw$Pi4PFtMI6AqFiHUYBNJY2cMjKtVFSz3SLGvg9OBaZqw', 'joseph.frost@example.test', 1, 1783209600);

INSERT OR IGNORE INTO dash_app (appname, description) VALUES
  ('ticketeer', 'Ticket intake and resolution tracking'),
  ('peachfuzz', 'Team board for dashboards and status'),
  ('checkmate', 'Checklist and verification workflows'),
  ('machin8', 'Automation control surface'),
  ('overlord', 'Operations command dashboard'),
  ('dailysales-neo', 'Daily sales reporting dashboard');

INSERT OR IGNORE INTO dash_binding (username, appname) VALUES
  ('jill.valentine', 'ticketeer'),
  ('jill.valentine', 'peachfuzz'),
  ('jill.valentine', 'checkmate'),
  ('jill.valentine', 'machin8'),
  ('jill.valentine', 'overlord'),
  ('jill.valentine', 'dailysales-neo'),
  ('chris.redfield', 'ticketeer'),
  ('chris.redfield', 'peachfuzz'),
  ('chris.redfield', 'checkmate'),
  ('chris.redfield', 'overlord'),
  ('barry.burton', 'ticketeer'),
  ('barry.burton', 'machin8'),
  ('barry.burton', 'overlord'),
  ('rebecca.chambers', 'peachfuzz'),
  ('rebecca.chambers', 'checkmate'),
  ('rebecca.chambers', 'dailysales-neo'),
  ('albert.wesker', 'overlord'),
  ('albert.wesker', 'machin8'),
  ('albert.wesker', 'dailysales-neo'),
  ('brad.vickers', 'ticketeer'),
  ('richard.aiken', 'peachfuzz'),
  ('richard.aiken', 'checkmate'),
  ('forest.speyer', 'machin8'),
  ('kenneth.sullivan', 'dailysales-neo'),
  ('joseph.frost', 'ticketeer');

COMMIT;
