#include <stdio.h>
#define MAX_ITEMS 64
#ifdef DEBUG
#endif

/* Block comment */
typedef struct {
    unsigned int count;
    const char *name;
} Inventory;

static int total(const Inventory *inv) {
    // Line comment
    long sum = 0L;
    for (int i = 0; i < inv->count; i++) {
        sum += i * 2.5f;
    }
    char c = 'x'; char esc = '\n';
    printf("%s has %d items\n", inv->name, inv->count);
    return sum > 0 ? (int)sum : -1;
}

int main(void) {
    Inventory inv = { 3, "bag" };
    if (total(&inv) == 0x10) return 1; else return 0;
}
/* a block
   comment */ int after = 1;
