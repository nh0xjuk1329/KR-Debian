UPDATE mails
SET reward_gold = 10000000, reward_gem = 10000, reward_stamina = 10000
WHERE is_received = 0 AND global_id IS NULL
  AND sender = 'System' AND title = 'Welcome to King''s Raid!'
  AND content = 'Thank you for playing on this private server. Enjoy your adventure!'
  AND (reward_gold, reward_gem, reward_stamina) = (100000000, 100000, 100000);
