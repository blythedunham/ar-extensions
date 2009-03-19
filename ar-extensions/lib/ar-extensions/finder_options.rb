# ActiveRecord::Extensions::FinderOptions provides additional functionality to the ActiveRecord
# ORM library created by DHH for Rails.
#
# == Using finder_sql_to_string
# Expose the finder sql to a string. The options are identical to those accepted by <tt>find(:all, options)</tt>
# the find method takes.
# === Example:
#   sql = Contact.finder_sql_to_string(:include => :primary_email_address)
#   Contact.find_by_sql(sql + 'USE_INDEX(blah)')
#
# == Enhanced Finder Options
# Add index hints, keywords, and pre and post SQL to the query without writing direct SQL
# === Parameter options:
# * <tt>:pre_sql</tt> appends SQL after the SELECT and before the selected columns
#
#  sql = Contact.find :first, :pre_sql => "HIGH_PRIORITY", :select => 'contacts.name', :conditions => 'id = 5'
#  SQL> SELECT HIGH_PRIORITY contacts.name FROM `contacts` WHERE id = 5
#
# * <tt>:post_sql</tt> appends additional SQL to the end of the statement
#  Contact.find :first, :post_sql => 'FOR UPDATE', :select => 'contacts.name', :conditions => 'id = 5'
#  SQL> SELECT contacts.name FROM `contacts` where id == 5 FOR UPDATE
#
#  Book.find :all, :post_sql => 'USE_INDEX(blah)'
#  SQL> SELECT books.* FROM `books` USE_INDEX(blah)
#
# * <tt>:override_select</tt> is used to override the <tt>SELECT</tt> clause of eager loaded associations
# The <tt>:select</tt> option is ignored by the vanilla ActiveRecord when using eager loading with associations (when <tt>:include</tt> is used)
# (refer to http://dev.rubyonrails.org/ticket/5371)
# The <tt>:override_select</tt> options allows us to directly specify a <tt>SELECT</tt> clause without affecting the operations of legacy code  (ignore <tt>:select</tt>)
# of the current code. Several plugins are available that enable select with eager loading
# Several plugins exist to force <tt>:select</tt> to work with eager loading.
#
# <tt>script/plugin install http://arperftoolkit.rubyforge.org/svn/trunk/eload_select/ </tt>
#
# * <tt>:having</tt> only works when <tt>:group</tt> option is specified
#  Book.find(:all, :select => 'count(*) as count_all, topic_id', :group => :topic_id, :having => 'count(*) > 1')
#  SQL>SELECT count(*) as count_all, topic_id FROM `books`  GROUP BY topic_id HAVING count(*) > 1
#
# == Developers
# * Blythe Dunham http://blythedunham.com
#
# == Homepage
# * Project Site: http://www.continuousthinking.com/tags/arext
# * Rubyforge Project: http://rubyforge.org/projects/arext
# * Anonymous SVN: svn checkout svn://rubyforge.org/var/svn/arext
#
require 'active_record/version'
module ActiveRecord::Extensions::FinderOptions
  def self.included(base)

    #alias and include only if not yet defined
    unless base.respond_to?(:construct_finder_sql_ext)
      base.extend ClassMethods
      base.extend ActiveRecord::Extensions::SqlGeneration
      base.class_eval do
        class << self
          VALID_FIND_OPTIONS.concat([:pre_sql, :post_sql, :keywords, :ignore, :rollup, :override_select, :having, :index_hint])
          alias_method              :construct_finder_sql, :construct_finder_sql_ext
          alias_method_chain        :construct_finder_sql_with_included_associations, :ext
        end
      end
   end
  end

  module ClassMethods
    # Return a string containing the SQL used with the find(:all)
    # The options are the same as those with find(:all)
    #
    # Additional parameter of
    # <tt>:force_eager_load</tt> forces eager loading even if the
    #  column is not referenced.
    #
    #   sql = Contact.finder_sql_to_string(:include => :primary_email_address)
    #   Contact.find_by_sql(sql + 'USE_INDEX(blah)')
    def finder_sql_to_string(options)
      
      select_sql = self.send(
        (use_eager_loading_sql?(options) ? :finder_sql_with_included_associations : :construct_finder_sql),
        options.reject{|k,v| k == :force_eager_load}).strip

    end

    protected

    # use eager loading sql (join associations) if inclu
    def use_eager_loading_sql?(options)# :nodoc:
      include_associations = merge_includes(scope(:find, :include), options[:include])
      return ((include_associations.any?) &&
              (options[:force_eager_load].is_a?(TrueClass) ||
               references_eager_loaded_tables?(options)))

    end

    # construct_finder_sql is called when not using eager loading (:include option is NOT specified)
    def construct_finder_sql_ext(options) # :nodoc:

      #add piggy back option if plugin is installed
      add_piggy_back!(options) if self.respond_to? :add_piggy_back!

      scope = scope(:find)
      sql = pre_sql_statements(options)
      sql  << "#{options[:select] || options[:override_select] || (scope && scope[:select]) || default_select(options[:joins] || (scope && scope[:joins]))} "
      sql << "FROM #{options[:from]  || (scope && scope[:from]) || quoted_table_name} "
      sql << "#{options[:index_hint]} " if options[:index_hint]

      add_joins!(sql, options[:joins], scope)
      add_conditions!(sql, options[:conditions], scope)
      add_group_with_having!(sql, options[:group], options[:having], scope)
      
      add_order!(sql, options[:order], scope)
      add_limit!(sql, options, scope)
      add_lock!(sql, options, scope)

      sql << post_sql_statements(options)
      sql

    end

    #override the constructor for use with associations (:include option)
    #directly use eager select if that plugin is loaded instead of this one
    def construct_finder_sql_with_included_associations_with_ext(options, join_dependency)#:nodoc
      if respond_to?(:construct_finder_sql_with_included_associations_with_eager_select)
        return construct_finder_sql_with_included_associations_with_eager_select(options, join_dependency)
      else
        scope = scope(:find)
        sql = pre_sql_statements(options)
        sql << "#{options[:override_select]||column_aliases(join_dependency)} FROM #{(scope && scope[:from]) || options[:from] || quoted_table_name} "
        sql << "#{options[:index_hint]} " if options[:index_hint]
        sql << join_dependency.join_associations.collect{|join| join.association_join }.join


        add_joins!(sql, options[:joins], scope)
        add_conditions!(sql, options[:conditions], scope)


        add_limited_ids_condition!(sql, options_with_group(options), join_dependency) if !using_limitable_reflections?(join_dependency.reflections) && ((scope && scope[:limit]) || options[:limit])

        add_group_with_having!(sql, options[:group], options[:having], scope)
        add_order!(sql, options[:order], scope)
        add_limit!(sql, options, scope) if using_limitable_reflections?(join_dependency.reflections)
        add_lock!(sql, options, scope)

        sql << post_sql_statements(options)

        return sanitize_sql(sql)
      end
    end

    #generate the finder sql for use with associations (:include => :something)
    def finder_sql_with_included_associations(options = {})#:nodoc
      join_dependency = ActiveRecord::Associations::ClassMethods::JoinDependency.new(self, merge_includes(scope(:find, :include), options[:include]), options[:joins])
      sql = construct_finder_sql_with_included_associations_with_ext(options, join_dependency)
    end
    

    # Before Version 2.3.0 there was no :having option
    # Add this option to previous versions by overriding add_group!
    # to accept a hash with keys :group and :having instead of just group
    # this avoids having to completely rewrite dependent functions like
    # construct_finder_sql_for_association_limiting

    if ActiveRecord::VERSION::STRING < '2.3.1'
      #add_group! in version 2.3 adds having already
      #copy that implementation

      def add_group_with_having!(sql, group, having, scope =:auto)
        if group
          sql << " GROUP BY #{group}"
          sql << " HAVING #{sanitize_sql(having)}" if having
        else
          scope = scope(:find) if :auto == scope
          if scope && (scoped_group = scope[:group])
            sql << " GROUP BY #{scoped_group}"
            sql << " HAVING #{sanitize_sql(scope[:having])}" if scope[:having]
          end
        end
      end

      def add_group!(sql, group_options, scope = :auto)#:nodoc:
        group, having = if group_options.is_a?(Hash) && group_options.has_key?(:group)
          [group_options[:group] , group_options[:having]]
        else
          [group_options, nil]
        end
        add_group_with_having!(sql, group, having, scope)
      end

      def options_with_group(options)#:nodoc:
        if options[:group]
          options.merge(:group => {:group => options[:group], :having => options[:having]})
        else
          options
        end
      end

    #for Version 2.3 and greater, define options_with_group to pass itself
    else
      def options_with_group(options)#:nodoc:
        options
      end
      
      def add_group_with_having!(sql, group, having, scope =:auto)#:nodoc:
        add_group!(sql, group, having, scope)
      end
    end

  end
end
