<!DOCTYPE html>
<html lang="<?= $lang ?>">
<head>
  <title><?php echo htmlspecialchars($title); ?></title>
  <style>
    /* across
       lines */
    .item { color: red; }
  </style>
</head>
<body>
<?php
/* A comment with ?> inside
   stays a comment */
foreach ($items as $item): // done ?>
  <a class="item <?= $item->cls ?>" href="<?= url($item) ?>"><?= $item->name ?></a>
<?php endforeach; ?>
<script>
  const total = <?= count($items) ?>;
  const label = `a ${total}
  items`;
</script>
<?xml-stylesheet href="x"?>
<?php
$sql = <<<SQL
  SELECT 1 ?> 2
  SQL;
?>
</body>
</html>
