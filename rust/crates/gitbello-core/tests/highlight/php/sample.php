<?php
declare(strict_types=1);

namespace App\Models;

use App\Contracts\HasName;

/** A product in the catalogue. */
#[Entity(table: "products")]
final class Product extends Model implements HasName
{
    public const MAX_PRICE = 1_000;
    private static int $count = 0;

    public function __construct(private string $name, protected ?float $price = null)
    {
        self::$count++;
    }

    // Line comment.
    # Hash comment.
    public function label(): string
    {
        $tag = 'it\'s';
        if ($this->price === null || !isset($this->name)) {
            return "{$this->name} (no price)\n";
        } elseif ($this->price > self::MAX_PRICE) {
            throw new \InvalidArgumentException("too much: $this->price");
        }
        foreach ([1, 2.5, 0x1F] as $i => $value) {
            echo $value . PHP_EOL;
        }
        $fn = fn(int $x): int => $x * 2;
        $text = <<<EOT
            Hello {$this->name}, $tag
            EOT;
        return match (true) {
            $fn(1) > 1 => sprintf('%s: %.2f', $this->name, $this->price),
            default => $tag,
        };
    }
}
?>
<p><?= htmlspecialchars($name) ?></p>
