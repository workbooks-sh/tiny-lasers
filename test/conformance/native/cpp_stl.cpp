#include <cstdio>
#include <string>
#include <vector>
#include <algorithm>
#include <numeric>
int main() {
  std::vector<int> v = {5, 3, 8, 1, 9, 2};
  std::sort(v.begin(), v.end());
  int sum = std::accumulate(v.begin(), v.end(), 0);
  std::string s = "sorted:";
  for (int x : v) s += " " + std::to_string(x);
  printf("%s sum=%d\n", s.c_str(), sum);
  return sum == 28 ? 42 : 1;
}
