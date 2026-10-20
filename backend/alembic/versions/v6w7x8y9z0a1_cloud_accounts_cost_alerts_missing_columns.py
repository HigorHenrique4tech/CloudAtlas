"""add columns declared in models but missing from migrations

Revision ID: v6w7x8y9z0a1
Revises: u5v6w7x8y9z0
Create Date: 2026-10-20

O banco de produção original foi criado por create_all() e carimbado no
Alembic, então estas colunas existiam lá mas nunca tiveram migration. Em um
banco criado só por migrations (ex.: reconstrução da produção) qualquer
SELECT em cloud_accounts falhava com UndefinedColumn (HTTP 500), inclusive a
tela de contas cloud e a conexão do Microsoft 365.

Idempotente: só adiciona o que ainda não existe.
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy import inspect as sa_inspect

revision = 'v6w7x8y9z0a1'
down_revision = 'u5v6w7x8y9z0'
branch_labels = None
depends_on = None


# (tabela, coluna) -> Column a criar
def _columns():
    return {
        'cloud_accounts': [
            sa.Column('allocation_tags', JSONB, nullable=True),
            sa.Column('bigquery_project', sa.String(255), nullable=True),
            sa.Column('bigquery_dataset', sa.String(255), nullable=True),
            sa.Column('bigquery_table', sa.String(255), nullable=True),
            sa.Column('billing_export_enabled', sa.Boolean(), nullable=False,
                      server_default=sa.false()),
        ],
        'cost_alerts': [
            sa.Column('last_evaluated_at', sa.DateTime(), nullable=True),
            sa.Column('last_triggered_at', sa.DateTime(), nullable=True),
        ],
    }


def upgrade():
    inspector = sa_inspect(op.get_bind())
    tables = set(inspector.get_table_names())
    for table, columns in _columns().items():
        if table not in tables:
            continue
        existing = {c['name'] for c in inspector.get_columns(table)}
        for column in columns:
            if column.name not in existing:
                op.add_column(table, column)


def downgrade():
    inspector = sa_inspect(op.get_bind())
    tables = set(inspector.get_table_names())
    for table, columns in _columns().items():
        if table not in tables:
            continue
        existing = {c['name'] for c in inspector.get_columns(table)}
        for column in columns:
            if column.name in existing:
                op.drop_column(table, column.name)
