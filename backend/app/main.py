from typing import List, Optional
from fastapi import FastAPI, Depends, HTTPException
from sqlmodel import Session, select

from .database import engine, init_db, get_session
from .models import (
    Diver, DiverCreate, DiverRead,
    Site, SiteCreate, SiteRead,
    Dive, DiveCreate, DiveRead,
)


app = FastAPI(
    title="Scuba Dive Log",
    description="A personal dive log API — divers, sites, and dives.",
    version="0.1.0",
)


@app.on_event("startup")
def on_startup() -> None:
    init_db()


@app.get("/", tags=["meta"])
def root():
    return {"app": "Scuba Dive Log", "version": "0.1.0", "docs": "/docs"}


# --------- Divers ---------

@app.post("/divers", response_model=DiverRead, tags=["divers"])
def create_diver(diver_in: DiverCreate, session: Session = Depends(get_session)):
    diver = Diver.model_validate(diver_in)
    session.add(diver)
    session.commit()
    session.refresh(diver)
    return diver


@app.get("/divers", response_model=List[DiverRead], tags=["divers"])
def list_divers(session: Session = Depends(get_session)):
    return session.exec(select(Diver)).all()


# --------- Sites ---------

@app.post("/sites", response_model=SiteRead, tags=["sites"])
def create_site(site_in: SiteCreate, session: Session = Depends(get_session)):
    site = Site.model_validate(site_in)
    session.add(site)
    session.commit()
    session.refresh(site)
    return site


@app.get("/sites", response_model=List[SiteRead], tags=["sites"])
def list_sites(session: Session = Depends(get_session)):
    return session.exec(select(Site)).all()


# --------- Dives ---------

@app.post("/dives", response_model=DiveRead, tags=["dives"])
def create_dive(dive_in: DiveCreate, session: Session = Depends(get_session)):
    if not session.get(Diver, dive_in.diver_id):
        raise HTTPException(404, f"Diver {dive_in.diver_id} not found")
    if not session.get(Site, dive_in.site_id):
        raise HTTPException(404, f"Site {dive_in.site_id} not found")
    dive = Dive.model_validate(dive_in)
    session.add(dive)
    session.commit()
    session.refresh(dive)
    return dive


@app.get("/dives", response_model=List[DiveRead], tags=["dives"])
def list_dives(
    site_id: Optional[int] = None,
    diver_id: Optional[int] = None,
    min_rating: Optional[int] = None,
    session: Session = Depends(get_session),
):
    q = select(Dive)
    if site_id is not None:
        q = q.where(Dive.site_id == site_id)
    if diver_id is not None:
        q = q.where(Dive.diver_id == diver_id)
    if min_rating is not None:
        q = q.where(Dive.rating >= min_rating)
    return session.exec(q).all()


# --------- Stats ---------

@app.get("/divers/{diver_id}/stats", tags=["divers"])
def diver_stats(diver_id: int, session: Session = Depends(get_session)):
    if not session.get(Diver, diver_id):
        raise HTTPException(404, f"Diver {diver_id} not found")

    dives = session.exec(select(Dive).where(Dive.diver_id == diver_id)).all()
    if not dives:
        return {"diver_id": diver_id, "total_dives": 0}

    gas_pairs = [(d.tank_pressure_start_bar, d.tank_pressure_end_bar)
                 for d in dives
                 if d.tank_pressure_start_bar is not None and d.tank_pressure_end_bar is not None]
    rated = [d.rating for d in dives if d.rating is not None]

    return {
        "diver_id": diver_id,
        "total_dives": len(dives),
        "total_bottom_time_min": sum(d.duration_min for d in dives),
        "avg_max_depth_m": round(sum(d.max_depth_m for d in dives) / len(dives), 1),
        "avg_gas_consumed_bar": round(sum(s - e for s, e in gas_pairs) / len(gas_pairs), 1) if gas_pairs else None,
        "avg_rating": round(sum(rated) / len(rated), 2) if rated else None,
    }
