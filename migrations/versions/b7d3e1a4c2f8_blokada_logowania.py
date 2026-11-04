"""Blokada konta po nieudanych logowaniach

Revision ID: b7d3e1a4c2f8
Revises: 94c5cf7bdeb0
Create Date: 2026-11-04 12:00:00

"""
from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision = 'b7d3e1a4c2f8'
down_revision = '94c5cf7bdeb0'
branch_labels = None
depends_on = None


def upgrade():
    op.add_column('users', sa.Column('failed_logins', sa.Integer(), server_default='0', nullable=False))
    op.add_column('users', sa.Column('locked_until', sa.DateTime(timezone=True), nullable=True))


def downgrade():
    op.drop_column('users', 'locked_until')
    op.drop_column('users', 'failed_logins')
