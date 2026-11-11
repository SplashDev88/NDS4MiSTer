#include "../src/replay/GeometrySubmissionObserver.h"
#include <cassert>
#include <iostream>
int main() {
    using nds4mister::replay::GeometrySubmissionObserver;
    GeometrySubmissionObserver o;
    auto frame = [&](unsigned data) { o.command(0x23, data); o.command(0x50, 0); };
    frame(1); frame(1); assert(o.counts.compared == 0);
    frame(1); assert(o.counts.identical == 1);
    frame(2); assert(o.counts.identical == 1);
    o.command(0x24,2); o.command(0x50,0); assert(o.counts.identical == 1);
    o.command(0x24,2); o.command(0x50,1); assert(o.counts.identical == 1);
    o.command(0x50,1); o.command(0x50,1); assert(o.counts.identical == 1);
    for(unsigned i=0;i<GeometrySubmissionObserver::Capacity+2;++i) o.command(0x23,1);
    o.command(0x50,0); assert(o.counts.overflow == 1);
    frame(1); assert(o.counts.identical == 1);
    frame(1); assert(o.counts.identical == 2);
    o.reset(); frame(1); frame(1); assert(o.counts.compared == 0);
    frame(1); assert(o.counts.identical == 1);
    std::cout << "GEOMETRY_SUBMISSION_OBSERVER_PASS boundaries values tags length swap overflow reset\n";
}
