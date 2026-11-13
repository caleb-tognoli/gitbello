-- Schema
CREATE TABLE users (
    id BIGSERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL DEFAULT 'it''s me',
    "order" INTEGER,
    created TIMESTAMP DEFAULT now()
);

/* Queries */
select u.name, count(*) as total
from users u
left join orders o on o.user_id = u.id
where u.created > '2024-01-01' and o.amount >= 10.5e2
group by u.name
having count(*) > 1
order by total desc
limit 10;

SELECT CASE WHEN active THEN 'yes' ELSE 'no' END FROM [dbo].[Users] WHERE id = @id;
UPDATE users SET name = :name, flags = E'a\tb' WHERE id = $1 AND tag::text IS NOT NULL;
INSERT INTO log (msg) VALUES (N'naïve'), (NULL), (TRUE);
DECLARE @@total INT = 0;
/* a block
   comment */ SELECT 1;
SELECT 'a string
over lines' AS note;
