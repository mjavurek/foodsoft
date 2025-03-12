class Api::V1::MirkoController < Api::V1::BaseController
  before_action -> { doorkeeper_authorize! 'orders:read' }

  def index
    time_now = Time.now
    time_range_open = time_now.weeks_ago(1)..time_now.next_year
    time_range_closed = time_now.weeks_ago(5)..time_now.weeks_ago(-1)
    common_scope = GroupOrder
                 .includes(group_order_articles: { order_article: :article }, order: :supplier)
                 .references(:orders)
                 .where(ordergroup_id: current_user.ordergroup.id)
                 .limit(200)
    gos = common_scope.where(orders: { ends: time_range_open, state: "open", pickup: nil })
            .or(common_scope.where(orders: { pickup: time_range_closed, state: %w[finished received closed] }))

    render json: gos, each_serializer: MirkoSerializer
  end
end
