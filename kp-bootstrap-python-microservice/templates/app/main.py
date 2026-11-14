from fastapi import FastAPI

from app.api.routes import health
from app.config import Settings, get_settings
from app.core.logging import configure_logging


def create_app() -> FastAPI:
    settings: Settings = get_settings()
    configure_logging(settings.log_level)

    app = FastAPI(title=settings.app_name)
    app.include_router(health.router)
    return app
