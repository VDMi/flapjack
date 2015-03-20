#!/usr/bin/env ruby

require 'active_support/concern'

module Flapjack
  module Gateways
    class JSONAPI < Sinatra::Base
      module Helpers
        module SwaggerLinksDocs

          extend ActiveSupport::Concern

          # included do
          # end

          class_methods do

            def swagger_post_links(resource, klass)

              single = resource.singularize

              _, multiple_links = klass.association_klasses

              multiple_links.each_pair do |link_name, link_data|
                link_type = link_data[:type]

                swagger_path "/#{resource}/{#{single}_id}/links/#{link_name}" do
                  operation :post do
                    key :description, "Associate one or more #{link_name} to a #{single}"
                    key :operationId, "add_#{single}_#{link_name}"
                    key :consumes, [JSONAPI_MEDIA_TYPE]
                    parameter do
                      key :name, "#{single}_id".to_sym
                      key :in, :path
                      key :description, "Id of a #{single}"
                      key :required, true
                      key :type, :string
                    end
                    parameter do
                      key :name, :data
                      key :in, :body
                      key :description, "#{link_name} to associate with the #{single}"
                      key :required, true
                      schema do
                        key :type, :array
                        items do
                          key :"$ref", "#{link_type}Reference".to_sym
                        end
                      end
                    end
                    response 204 do
                      key :description, ''
                    end
                    # response :default do
                    #   key :description, 'unexpected error'
                    #   schema do
                    #     key :'$ref', :ErrorModel
                    #   end
                    # end
                  end
                end

              end
            end

            def swagger_get_links(resource, klass)

              # # TODO needs to return full linked klass type
              # # TODO needs to distinguish between single/multiple for param type

              # singular_links = klass.jsonapi_singular_associations
              # multiple_links = klass.jsonapi_multiple_associations

              # single = resource.singularize

              # get_docs = proc do |ln|
              #   operation :get do
              #     key :description, "Get all #{resource}"
              #     key :operationId, "get_all_#{resource}"
              #     key :produces, [JSONAPI_MEDIA_TYPE]
              #     parameter do
              #       key :name, :fields
              #       key :in, :query
              #       key :description, 'Comma-separated list of fields to return'
              #       key :required, false
              #       key :type, :string
              #     end
              #     parameter do
              #       key :name, :sort
              #       key :in, :query
              #       key :description, ''
              #       key :required, false
              #       key :type, :string
              #     end
              #     parameter do
              #       key :name, :filter
              #       key :in, :query
              #       key :description, ''
              #       key :required, false
              #       key :type, :string
              #     end
              #     parameter do
              #       key :name, :include
              #       key :in, :query
              #       key :description, ''
              #       key :required, false
              #       key :type, :string
              #     end
              #     parameter do
              #       key :name, :page
              #       key :in, :query
              #       key :description, 'Page number'
              #       key :required, false
              #       key :type, :integer
              #     end
              #     parameter do
              #       key :name, :per_page
              #       key :in, :query
              #       key :description, "Number of #{resource} per page"
              #       key :required, false
              #       key :type, :integer
              #     end
              #     response 200 do
              #       key :description, "GET #{resource} response"
              #       schema do
              #         key :'$ref', swagger_type_data_plural
              #       end
              #     end
              #     # response :default do
              #     #   key :description, 'unexpected error'
              #     #   schema do
              #     #     key :'$ref', :ErrorModel
              #     #   end
              #     # end
              #   end
              # end

              # TODO get klasses for these associations

              # model_type = klass.name.demodulize
              # model_type_plural = model_type.pluralize

              # swagger_type_data = "jsonapi_data_#{model_type}".to_sym
              # swagger_type_data_plural = "jsonapi_data_#{model_type_plural}".to_sym

              # linked.each_pair do |link_name, link_klass|

              #   swagger_path "/#{resource}/{#{single}_id}/#{link_name}" do
              #     get_docs.call(link_name)
              #   end

              #   swagger_path "/#{resource}/{#{single}_id}/links/#{link_name}" do
              #     get_docs.call(link_name)
              #   end
              # end
            end

            def swagger_patch_links(resource, klass)
              single = resource.singularize

              singular_links, multiple_links = klass.association_klasses

              singular_links.each_pair do |link_name, link_data|
                link_type = link_data[:type]
                swagger_path "/#{resource}/{#{single}_id}/links/#{link_name}" do
                  operation :patch do
                    key :description, "Replace associated #{link_name} for a #{single}"
                    key :operationId, "replace_#{single}_#{link_name}"
                    key :consumes, [JSONAPI_MEDIA_TYPE]
                    parameter do
                      key :name, "#{single}_id".to_sym
                      key :in, :path
                      key :description, "Id of a #{single}"
                      key :required, true
                      key :type, :string
                    end
                    parameter do
                      key :name, :data
                      key :in, :body
                      key :description, "#{link_name} association to replace for the #{single}"
                      key :required, true
                      schema do
                        key :"$ref", "#{link_type}Reference".to_sym
                      end
                    end
                    response 204 do
                      key :description, ''
                    end
                    # response :default do
                    #   key :description, 'unexpected error'
                    #   schema do
                    #     key :'$ref', :ErrorModel
                    #   end
                    # end
                  end
                end
              end

              multiple_links.each_pair do |link_name, link_data|
                link_type = link_data[:type]
                swagger_path "/#{resource}/{#{single}_id}/links/#{link_name}" do
                  operation :patch do
                    key :description, "Replace associated #{link_name} for a #{single}"
                    key :operationId, "replace_#{single}_#{link_name}"
                    key :consumes, [JSONAPI_MEDIA_TYPE]
                    parameter do
                      key :name, "#{single}_id".to_sym
                      key :in, :path
                      key :description, "Id of a #{single}"
                      key :required, true
                      key :type, :string
                    end
                    parameter do
                      key :name, :data
                      key :in, :body
                      key :description, "#{link_name} associations to replace for the #{single}"
                      key :required, true
                      schema do
                        key :type, :array
                        items do
                          key :"$ref", "#{link_type}Reference".to_sym
                        end
                      end
                    end
                    response 204 do
                      key :description, ''
                    end
                    # response :default do
                    #   key :description, 'unexpected error'
                    #   schema do
                    #     key :'$ref', :ErrorModel
                    #   end
                    # end
                  end
                end
              end
            end

            def swagger_delete_links(resource, klass)
              single = resource.singularize

              _, multiple_links = klass.association_klasses

              multiple_links.each_pair do |link_name, link_data|
                link_type = link_data[:type]

                swagger_path "/#{resource}/{#{single}_id}/links/#{link_name}" do
                  operation :delete do
                    key :description, "Remove one or more #{link_name} from a #{single}"
                    key :operationId, "remove_#{single}_#{link_name}"
                    key :consumes, [JSONAPI_MEDIA_TYPE]
                    parameter do
                      key :name, "#{single}_id".to_sym
                      key :in, :path
                      key :description, "Id of a #{single}"
                      key :required, true
                      key :type, :string
                    end
                    parameter do
                      key :name, :data
                      key :in, :body
                      key :description, "#{link_name} to remove from the #{single}"
                      key :required, true
                      schema do
                        key :type, :array
                        items do
                          key :"$ref", "#{link_type}Reference".to_sym
                        end
                      end
                    end
                    response 204 do
                      key :description, ''
                    end
                    # response :default do
                    #   key :description, 'unexpected error'
                    #   schema do
                    #     key :'$ref', :ErrorModel
                    #   end
                    # end
                  end
                end

              end

            end

          end

        end
      end
    end
  end
end