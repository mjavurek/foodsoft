class Api::V2::PickupController < Api::BaseController
  
  skip_before_action :verify_authenticity_token 
  # This endpoint is an API, don’t enforce CSRF
  # prevents foodsoft CSRF error if API is called via AJAX request

  def index   
    ordergroup_id = params.fetch(:ordergroup_id, nil) || 
      (current_user.ordergroup ? current_user.ordergroup.id : nil)
    render_ordergroup_orders(ordergroup_id)
  end

  def show
    result = params.require(:id) 
    if result == "users" 
      render_users_and_ordergroups
    elsif result == "orders"
      # get orders for all ordergroups
      order_ids = params.fetch(:ids, "").split(",").map(&:to_i)
      if order_ids.any?
        render_orders(order_ids)
      else 
        render_orders_overview
      end
    end
  end

  def update
    # update GroupOrderArticle attributes like received and create order comments
    order_id = params.require(:id)
    comment = params.fetch(:comment, "")
    if comment && order_id
      Order.transaction do
        order = Order.find(order_id)
        order.comments.create(user: current_user, text:comment)
      end
    end
    GroupOrderArticle.transaction do
      params.fetch(:updates, {}).each do |article_id, property_updates| 
        goa = GroupOrderArticle.find(article_id)
        property_updates.each do |property, value|
          goa.update_attribute(property, value) # allows updates for closed orders, skips validation
          if property == "result" && params.fetch(:update_result_sum, true)
            total = GroupOrderArticle.where(order_article_id: goa.order_article_id).sum(:result)
            goa.order_article.update!(units_received: total)  
          end
        end
      end
    end
  end

  private

  def time_now
    if Rails.env.development?
      #Time.new(2025, 12, 17)
      Time.new(2026, 10, 11)
    else
      Time.current
    end
  end

  def last_week
    time_now.weeks_ago(1)..time_now.next_year
  end

  def last_weeks
    time_now.weeks_ago(params.fetch(:weeks, 5))..time_now.weeks_since(1)
  end

  def unit_name(unit)
    ArticleUnitsLib.get_translated_symbol_for_code(unit) || 
    ArticleUnitsLib.get_translated_name_for_code(unit)
  end

  def content_per_ordered_unit(article, unit) # "GRM", "MLT"
    article.convert_quantity(1, article.group_order_unit, unit)
    rescue PriceCalculation::UnsupportedUnitConversionError => e
      nil
  end

  def price_per_ordered_unit(article)
    article.convert_quantity(article.price, article.group_order_unit, article.supplier_order_unit)
  end

  # render methods

  def render_ordergroup_orders(ordergroup_id)
    base_scope = GroupOrder
      .includes(group_order_articles: { order_article: {article_version: :article_unit_ratios} },
                order: [:supplier, :comments])
      .references(:orders)
      .where(ordergroup_id: ordergroup_id)
      .limit(200)
    group_orders = base_scope.where(
      orders: {
        state: "open",
        pickup: nil, # z.B. Leergut Rückgabe
        ends: last_week
      }
    ).or(
      base_scope.where(
        orders: {
          state: "open",
          supplier_id: nil, # Lager
          ends: last_week
        }
      )  
    ).or(
      base_scope.where(
        orders: {
          state: %w[finished received closed],
          pickup: last_weeks
        }
      )
    )

    #require "byebug"; byebug
  
    render json: 
    {
      group_orders: group_orders.map { |go|
        {
          id: go.id, 
          ends: go.order.ends, # date where order ends # rubymate:disable-line
          pickup: go.order.pickup, # date where order pickup starts
          state: go.order.state,
          order_id: go.order.id,
          name: go.order.name,
          supplier_note: go.order.supplier ? go.order.supplier.note : ""  ,
          articles: go.group_order_articles.map { |goa|
            a = goa.order_article.article_version
            { id: goa.id,
              name: a.name,
              unit: a.unit,
              unit_group_order: a.group_order_unit, 
              unit_group_order_name: unit_name(a.group_order_unit), 
              unit_billing: a.billing_unit,
              grams_per_ordered_unit: content_per_ordered_unit(a, "GRM"),
              milliliter_per_ordered_unit: content_per_ordered_unit(a, "MLT"),
              price: price_per_ordered_unit(a),
              deposit: a.deposit,

              ordered: goa.quantity,
              tolerance: goa.tolerance, 
              received: goa.result,   

              grouporder_article_id: goa.order_article.id, 
              ordered_total: goa.order_article.quantity, 
              received_total: goa.order_article.units_received, 
            }
          },
          comments: go.order.comments,
        }
      }         
    }
  end



  def render_orders(order_ids)
    orders = Order.where(id: order_ids).includes(
      :supplier,
      :comments, 
      order_articles:  { group_order_articles: { group_order: :ordergroup }}
    )

    render json:
    { 
      orders: orders.map { |order|
        { 
          id: order.id,
          name: order.name,
          state: order.state,
          ends: order.ends,
          pickup: order.pickup,
          supplier_note: order.supplier ? order.supplier.note : ""  ,
          articles: order.order_articles.map { |oa|
            a = oa.article_version
            oa.group_order_articles.any? ? { 
              id: oa.id,
              name: a.name,
              unit: a.unit,
              unit_group_order: a.group_order_unit, 
              unit_group_order_name: unit_name(a.group_order_unit), 
              unit_billing: a.billing_unit,
              grams_per_ordered_unit: content_per_ordered_unit(a, "GRM"),
              milliliter_per_ordered_unit: content_per_ordered_unit(a, "MLT"),
              price: price_per_ordered_unit(a),
              deposit: a.deposit,
              grouporders: oa.group_order_articles.map { |goa|
                { 
                  id: goa.id,
                  ordergroup_name: (goa.group_order.ordergroup ? goa.group_order.ordergroup.name : "none"),
                  ordered: goa.quantity,
                  tolerance: goa.tolerance, 
                  received: goa.result, 
                }
              },
              ordered: oa.quantity, # new !!!
              received: oa.units_received, # new!!!
            } : nil 
          }.compact, # remove nil elements
          comments: order.comments,
        }
      }
    }
  end

  def render_orders_overview
    orders = Order.where(
        state: %w[finished received closed],
        pickup: last_weeks
    ).includes(:supplier)

    render json:
    {
      orders: orders.map { |order|
        { # only overview for order selection, no article details
          id: order.id,
          name: order.name,
          state: order.state,
          ends: order.ends,
          pickup: order.pickup,
          supplier_note: order.supplier ? order.supplier.note : ""  
        }
      }
    }
  end

  def render_users_and_ordergroups
    # get all active users and their ordergroup (if member of an ordergroup)  
    ordergroup_subquery = Membership
      .joins(:group)
      .where(groups: { type: "Ordergroup" })
      .select("memberships.user_id, groups.*")
    users = User.undeleted
      .joins(
        "LEFT JOIN (#{ordergroup_subquery.to_sql}) AS ordergroups
        ON ordergroups.user_id = users.id"
      )     
      .select(
        "users.*,
        ordergroups.id   AS ordergroup_id,
        ordergroups.name AS ordergroup_name"
      )
    render json:  
    {
      users: users.map { |user|
        { 
          id: user.id, 
          name: user.name,
          email: user.email, 
          locale: user.locale, 
          ordergroup_id: user[:ordergroup_id] || nil,
          ordergroup_name:  user[:ordergroup_name] || nil,
        }
      }
    }
  end
end
