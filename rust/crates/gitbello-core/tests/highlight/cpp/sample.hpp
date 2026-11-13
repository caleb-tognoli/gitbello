#pragma once
#include <vector>
#include "inventory.h"

/// A bag of items.
namespace store {

template <typename T>
class [[nodiscard]] Bag final : public Container<T> {
public:
    explicit Bag(std::size_t capacity) noexcept : items_{}, capacity_(capacity) {}
    virtual ~Bag() override = default;

    constexpr bool empty() const { return items_.size() == 0; }
    auto add(T item) -> void {
        if (items_.size() >= MAX_ITEMS) throw std::length_error("full");
        items_.push_back(std::move(item));
    }

private:
    std::vector<T> items_;
    std::size_t capacity_ = 0x10;
};

}  // namespace store

auto raw = R"(C:\no\escapes "here")"; auto wide = L"wide\n";
char c = 'x'; int n = 1'000'000; double d = 1.5e3; float f = 2.0f;
struct Point { int x, y; };
enum class Color : uint8_t { Red, Green };
const char* name = nullptr; /* block */ bool ok = true;
