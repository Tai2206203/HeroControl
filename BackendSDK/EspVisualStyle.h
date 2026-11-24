#ifndef HC_ESP_VISUAL_STYLE_H
#define HC_ESP_VISUAL_STYLE_H
#include <stdbool.h>
#include <math.h>
typedef struct { bool known; double ratio, red, green, blue; } HCHeroHealth;
static inline HCHeroHealth HCHeroHealthValue(double current,double maximum,bool known) {
    HCHeroHealth result={false,0,0.55,0.55,0.6};
    if(!known || !isfinite(current) || !isfinite(maximum) || maximum<=0 || current<0 || current>maximum) return result;
    result.known=true;result.ratio=current/maximum;
    result.red=fmin(1,2*(1-result.ratio));result.green=fmin(1,2*result.ratio);result.blue=0.16;
    return result;
}
// Outer ring diameter fits inside the box, including its stroke and padding.
static inline double HCHeroBadgeSized(double width,double height,double desired) {
    if(!isfinite(width) || !isfinite(height) || !isfinite(desired) || desired<=0) return 0;
    double diameter=fmin(desired,fmin(width,height)-4);
    return diameter>=12 ? diameter : 0;
}
static inline double HCHeroBadgeDiameter(double width,double height) { return HCHeroBadgeSized(width,height,38); }
static inline double HCMinimapDragPosition(double origin,double delta,double dimension,double size) {
    if(!isfinite(origin) || !isfinite(delta) || !isfinite(dimension) || !isfinite(size) || dimension<=0 || size>dimension) return 0;
    return fmax(0,fmin(dimension-size,origin+delta))/dimension;
}
#endif
