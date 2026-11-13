using System;
using System.Collections.Generic;

#nullable enable
namespace Store;

/// <summary>A bag of items.</summary>
[Serializable]
public sealed record Item(string Name, int Count);

public class Bag<T> : IEnumerable<T> where T : notnull
{
    private readonly List<T> _items = new();
    public const int MaxItems = 64;

    public async Task<bool> AddAsync(T item, CancellationToken token = default)
    {
        if (_items.Count >= MaxItems) throw new InvalidOperationException("full");
        _items.Add(item);
        var label = $"Added {item} ({_items.Count:D2} of {{max}})";
        var path = @"C:\no\escapes ""quoted""";
        var both = $@"{path}\{label}";
        char c = 'x'; decimal price = 9.99m; long big = 0xFF_FFL;
        foreach (var x in _items) Console.WriteLine(x?.ToString() ?? "null");
        return await Task.FromResult(true); /* block */
    }
}
