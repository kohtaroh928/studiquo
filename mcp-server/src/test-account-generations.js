// Test double for RateCounter's per-account generation methods
// (nextAccountGeneration / retireAccountGeneration / upgradeAccountIfCurrent /
// purgeAll), with the same contract: one count per name, and an upgrade
// applied only if the count is unchanged.
export function accountGenerationMethods(name, generations, getData) {
  return {
    async nextAccountGeneration() {
      const next = (generations.get(name) ?? 0) + 1;
      generations.set(name, next);
      return next;
    },
    // Account deletion: the count moves on (as nextAccountGeneration) and the
    // real object also arms an alarm to clear it later.
    async retireAccountGeneration() {
      const next = (generations.get(name) ?? 0) + 1;
      generations.set(name, next);
      return next;
    },
    async purgeAll() {},
    async upgradeAccountIfCurrent(key, json, expectedGen) {
      if ((generations.get(name) ?? 0) !== expectedGen) return false;
      await getData().put(key, json);
      return true;
    },
  };
}
