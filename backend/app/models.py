from typing import Optional, List
from datetime import datetime
from sqlmodel import SQLModel, Field, Relationship


# ============== Diver ==============

class DiverBase(SQLModel):
    name: str
    age: Optional[int] = None
    city: Optional[str] = None
    school: Optional[str] = None
    cert_id: Optional[str] = None
    cert_level: Optional[str] = None


class Diver(DiverBase, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    dives: List["Dive"] = Relationship(back_populates="diver")


class DiverCreate(DiverBase):
    pass


class DiverRead(DiverBase):
    id: int


# ============== Site ==============

class SiteBase(SQLModel):
    name: str
    city: Optional[str] = None
    country: Optional[str] = None
    typical_max_depth_m: Optional[float] = None
    typical_visibility: Optional[str] = None
    current_strength: Optional[str] = None
    marine_life: Optional[str] = None
    hazards: Optional[str] = None


class Site(SiteBase, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    dives: List["Dive"] = Relationship(back_populates="site")


class SiteCreate(SiteBase):
    pass


class SiteRead(SiteBase):
    id: int


# ============== Dive ==============

class DiveBase(SQLModel):
    date: datetime
    diver_id: int = Field(foreign_key="diver.id")
    site_id: int = Field(foreign_key="site.id")
    duration_min: int
    max_depth_m: float
    water_temp_c: Optional[float] = None
    gas_mix: Optional[str] = None
    tank_pressure_start_bar: Optional[int] = None
    tank_pressure_end_bar: Optional[int] = None
    buddy: Optional[str] = None
    notes: Optional[str] = None
    rating: Optional[int] = None


class Dive(DiveBase, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    diver: Optional[Diver] = Relationship(back_populates="dives")
    site: Optional[Site] = Relationship(back_populates="dives")


class DiveCreate(DiveBase):
    pass


class DiveRead(DiveBase):
    id: int
