from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    app_name: str = Field(default="{{PROJECT_NAME}}")
    env: str = Field(default="development")
    host: str = Field(default="0.0.0.0")
    port: int = Field(default=8000)
    data_file: str = Field(default="data/{{PROJECT_NAME}}.json")
    basic_auth_user: str = Field(default="admin")
    basic_auth_password: str = Field(default="changeme")
    cache_ttl_seconds: int = Field(default=60)
    cache_max_size: int = Field(default=1024)
    log_level: str = Field(default="INFO")


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
