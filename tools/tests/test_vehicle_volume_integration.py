"""CPU reference for v006 vehicle cone support/quadrature; not GPU execution."""
import math
from pathlib import Path
import random
import unittest

ROOT=Path(__file__).resolve().parents[2]

def dot(a,b):return sum(x*y for x,y in zip(a,b))
def norm(a):
    n=math.sqrt(dot(a,a));return tuple(x/n for x in a)
def smooth(a,b,v):
    x=max(0,min(1,(v-a)/(b-a)));return x*x*(3-2*x)

def interval(q,ray,axis,outer,reach,end=160):
    b=dot(q,ray);c=dot(q,q)-reach*reach;disc=b*b-c
    if disc<=0:return None
    root=math.sqrt(disc);start=max(0,-b-root);stop=min(end,-b+root)
    if stop<=start:return None
    if outer<0:return start,stop
    z=dot(q,axis);dz=dot(ray,axis)
    if abs(dz)<1e-6:
        if z<=0:return None
    elif dz>0:start=max(start,-z/dz)
    else:stop=min(stop,-z/dz)
    if stop<=start:return None
    cos2=outer*outer;a=dz*dz-cos2;qb=2*(z*dz-cos2*b);qc=z*z-cos2*dot(q,q)
    if abs(a)<1e-6:
        if abs(qb)<1e-6:
            if qc<0:return None
        elif qb>0:start=max(start,-qc/qb)
        else:stop=min(stop,-qc/qb)
    else:
        cd=qb*qb-4*a*qc
        if cd<0:
            mid=(start+stop)*.5
            if (a*mid+qb)*mid+qc<0:return None
        else:
            qr=-.5*(qb+(1 if qb>=0 else -1)*math.sqrt(max(cd,0)))
            r0=qr/a;r1=qc/qr if abs(qr)>1e-12 else r0
            lo=min(r0,r1);hi=max(r0,r1)
            if a<0:start=max(start,lo);stop=min(stop,hi)
            elif start<lo:stop=min(stop,lo)
            else:start=max(start,hi)
    return (start,stop) if stop>start else None

def integrate(q,ray,steps,point=False):
    axis=(0,0,1);reach=3 if point else 20
    outer=-2 if point else math.cos(math.radians(22.5))
    inner=math.cos(math.radians(20))
    bounds=interval(q,ray,axis,outer,reach)
    if not bounds:return 0
    start,stop=bounds;ds=(stop-start)/steps;result=0
    for i in range(steps):
        p=tuple(q[k]+ray[k]*(start+(i+.5)*ds) for k in range(3))
        d2=max(dot(p,p),.04);direction=tuple(x/math.sqrt(d2) for x in p)
        cone=1 if point else smooth(outer,inner,dot(direction,axis))
        falloff=max(0,min(1,1-d2/(reach*reach)))
        phase=.91/(4*math.pi*max(1.09-.6*dot(direction,tuple(-x for x in ray)),.01)**1.5)
        result+=cone*falloff*falloff*phase/(1+.15*d2)
    return result*ds


class VehicleVolumeIntegration(unittest.TestCase):
    def test_random_support_matches_dense_geometric_membership(self):
        rng=random.Random(812)
        outer=math.cos(math.radians(22.5));axis=(0,0,1)
        for _ in range(600):
            q=tuple(rng.uniform(-25,25) for _ in range(3));ray=norm(tuple(rng.uniform(-1,1) for _ in range(3)))
            bounds=interval(q,ray,axis,outer,20,80)
            for i in range(160):
                t=(i+.5)*.5;p=tuple(q[k]+ray[k]*t for k in range(3));d2=dot(p,p)
                inside=p[2]>0 and d2<400 and p[2]*p[2]>=outer*outer*d2
                if inside:
                    self.assertIsNotNone(bounds,(q,ray,t))
                    self.assertTrue(bounds[0]-1e-4<=t<=bounds[1]+1e-4)
            if bounds:
                for f in (.001,.25,.5,.75,.999):
                    t=bounds[0]+(bounds[1]-bounds[0])*f;p=tuple(q[k]+ray[k]*t for k in range(3));d2=dot(p,p)
                    self.assertGreaterEqual(p[2],-1e-5)
                    self.assertLessEqual(d2,400.001)
                    self.assertGreaterEqual(p[2]*p[2]-outer*outer*d2,-.001)

    def test_axial_tangent_parallel_point_and_depth_limits(self):
        outer=math.cos(math.radians(22.5));axis=(0,0,1)
        self.assertEqual(interval((0,0,-10),(0,0,1),axis,outer,20),(10,30))
        self.assertIsNone(interval((0,0,-10),(0,0,-1),axis,outer,20))
        self.assertEqual(interval((0,0,0),(0,0,1),axis,outer,20),(0,20))
        self.assertIsNone(interval((21,0,10),(0,1,0),axis,outer,20))
        self.assertEqual(interval((0,0,-10),(0,0,1),axis,outer,20,15),(10,15))
        self.assertEqual(interval((0,0,-10),(0,0,1),axis,-2,3),(7,13))
        ray=norm((math.sin(math.radians(22.5)),0,outer))
        bounds=interval((.2,0,1),ray,axis,outer,20)
        self.assertTrue(bounds is None or all(math.isfinite(x) for x in bounds))

    def test_contiguous_sweep_has_no_interior_zero_slices_and_tracks_dense_reference(self):
        q=(12,-10,5);previous=None
        # Targets stay inside the 22.5 degree cone at z=8 (radius ~3.31).
        for i in range(101):
            y=-2.5+i*.05;target=(0,y,8);ray=norm(tuple(target[k]-q[k] for k in range(3)))
            value=integrate(q,ray,16);reference=integrate(q,ray,2048)
            self.assertGreater(value,0)
            self.assertLess(abs(value-reference)/max(reference,1e-12),.03)
            if previous is not None:self.assertLess(abs(value-previous),.002)
            previous=value
        for x in (-2,-1,0,1,2):
            ray=norm((-x,0,10));self.assertGreaterEqual(integrate((x,0,-5),ray,16,True),0)

    def test_vehicle_shader_is_separate_from_unchanged_lamp_integrator(self):
        old=(ROOT/'shaders/beamrt/beamrtLocalVolumeP_v005.hlsl').read_text()
        new=(ROOT/'shaders/beamrt/beamrtLocalVolumeP_v006.hlsl').read_text()
        start='float3 beamrtLocalScatter';end='// Finite, geometry-oriented'
        original=old[old.index(start):old.index(end)]
        self.assertEqual(new[new.index(start):new.index('// Vehicle-only support')],original)
        self.assertIn('if(!beamrtVehicleInterval(ray,endT,lamp,axis,startT,stopT)) return 0;',new)
        self.assertIn('j<16',new)
        for i in range(4):self.assertIn('beamrtVehicleScatter(ray,endT,vehiclePosition'+str(i),new)

if __name__=='__main__':unittest.main()
