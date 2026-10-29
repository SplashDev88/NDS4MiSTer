#include "replay_touch_input.h"
#include <cassert>
#include <iostream>

int main() {
 unsigned checks=0;
 for(const auto& text:{"0 1 2", "0 1 2 3 4", "0 0 1 1", "3 2 1 1", "0 6 1 1",
                       "-1 2 1 1", "+0 2 1 1", "0x0 2 1 1", "0 2 256 0", "0 2 0 192",
                       "0 2 -1 0", "0 2 0 -1", "0 2 1 1 # comment", "# comment",
                       "0 3 1 1\n2 4 2 2", "3 4 1 1\n1 2 2 2", "0 9999999999999999999999999 1 1"}) {
  bool failed=false;
  try {ReplayTouchInput t;std::istringstream input(text);t.Load(input,5);}
  catch(const std::exception&){failed=true;}
  assert(failed);++checks;
 }
 ReplayTouchInput t;
 std::istringstream input("\n1 3 0 191\n3 4 255 0\n6 8 128 96\n");t.Load(input,8);
 for(unsigned f=0;f<10;++f) {
  const auto* w=t.At(f);
  assert(bool(w)==(f>=1&&f<4||f>=6&&f<8));
  if(w)assert((f<3&&w->x==0&&w->y==191)||(f==3&&w->x==255&&w->y==0)||(f>=6&&w->x==128&&w->y==96));
  ++checks;
 }
 // Lookup is stateless, including checkpoint review in reverse frame order.
 assert(t.At(2)->x==0&&!t.At(0));++checks;
 std::istringstream empty(" \n\t\n");t.Load(empty,8);assert(!t.At(2));++checks;
 std::cout<<checks<<" touch input checks passed\n";
}
